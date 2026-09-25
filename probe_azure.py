#!/usr/bin/env python3
"""Probe which Azure AI models this subscription can deploy, and how fast.

Why this exists
    azure-config.sh lists the models 01-core deploys and LiteLLM serves to
    OpenClaw, and check_env.sh verifies each one before a deploy starts.
    Neither answers the question you actually have when choosing what goes in
    that list: which models can this subscription deploy today, in this
    region, and what do they cost you in latency?

    Azure differs from Bedrock and Vertex in one important way: a model
    cannot be called until it has been DEPLOYED into an account. So this
    works at three levels:

      catalog  Always. Reads the regional model catalog and the
               subscription's quota: every chat model from every provider
               (OpenAI, DeepSeek, Meta, Mistral, xAI, Anthropic, ...) offered
               with the deployment SKU, when each version retires, and how
               much quota is free.

      live     When 01-core has been applied. Calls every deployment already
               in the openclaw account and ranks them by latency.

      deploy   With --deploy. For each catalog model matching the filters,
               creates a temporary deployment in the openclaw account, calls
               it once, and deletes it. This is the only way to time -- or
               even prove -- a model that is not deployed, and it is slow:
               each model is a real deployment, created and removed one at a
               time.

Usage
    python3 probe_azure.py                      # catalog, plus live if deployed
    python3 probe_azure.py gpt-5 deepseek       # only models matching a filter
    python3 probe_azure.py --deploy grok llama  # temp-deploy and test matches
    python3 probe_azure.py --deploy             # temp-deploy and test EVERYTHING
    python3 probe_azure.py --tokens 800         # realistic generation length
    python3 probe_azure.py --location westus3
    python3 probe_azure.py --sku DataZoneStandard
    python3 probe_azure.py --no-live            # catalog only
    python3 probe_azure.py --check gpt-4.1:2025-04-14[:100]

    --check verifies one model:version (and optionally a capacity, in
    thousands of TPM) against the catalog and quota, and communicates through
    the exit code, so a shell pre-flight can gate a deploy on it -- the same
    contract probe_vertex.py and probe_bedrock.py offer. It needs no
    deployment. It rejects Anthropic models, which Azure will not deploy
    without your organization details.

All calls go to the account's Foundry endpoint, /openai/v1/chat/completions,
with the deployment name as "model". Verified 2026-09-24 to answer for both
OpenAI and non-OpenAI deployments, so one code path covers every provider.

Anthropic (Claude) models are listed but marked GATED: Azure refuses to
deploy them without "model provider data" -- your industry, organization
name, and country code -- so --deploy skips them.

Requirements
    The az CLI, logged in -- the same thing check_env.sh already needs.
    --deploy additionally needs 01-core applied and rights to create
    deployments in its account. Deliberately NO Python dependencies.
"""

import datetime
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

# Matches openclaw-core-rg in 01-core/main.tf, where the AI account lives.
CORE_RG = "openclaw-core-rg"
ACCOUNT_PREFIX = "openclaw-openai-"

# Temporary deployments are named with this prefix, so a run that was
# interrupted can be cleaned up by the next one without touching anything
# Terraform (or a human) created.
TEMP_PREFIX = "probe-tmp-"

# Capacity (thousands of TPM) for a temporary deployment. 1 is enough to
# exist but throttles to about one request a minute, which fails the probe.
TEMP_CAPACITY = 10

# custom_data.sh routes OpenAI-format models as LiteLLM azure/<deployment>
# and every other format as openai/<deployment> on the Foundry /openai/v1
# route, so any format can go in azure-config.sh except the gated ones.

# Formats Azure will not deploy without model provider data.
GATED_FORMATS = ("Anthropic",)


# ==============================================================================
# az CLI plumbing
# ==============================================================================

def az(args, timeout=180):
    """Run an az command and return (ok, parsed_json_or_error_text)."""
    try:
        out = subprocess.run(["az"] + args + ["--output", "json"],
                             capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        sys.exit("ERROR: az CLI not found in PATH.")
    except subprocess.TimeoutExpired:
        return False, "timed out after %ds" % timeout
    if out.returncode != 0:
        # az prints "ERROR: (Code) ..." then "Message: ..."; the Message line
        # is the readable one when present.
        err = out.stderr.strip()
        m = re.search(r"Message: (.*)", err) or re.search(r"ERROR: (.*)", err)
        return False, m.group(1).strip() if m else \
            (err.splitlines() or ["az exited %d" % out.returncode])[-1]
    try:
        return True, json.loads(out.stdout or "null")
    except ValueError:
        return True, None


def az_json(args, timeout=180):
    """az() for reads: return the parsed JSON, or None on any failure."""
    ok, data = az(args, timeout)
    return data if ok else None


def subscription():
    """Return the active subscription name, exiting if az is not logged in."""
    acct = az_json(["account", "show"], timeout=30)
    if not acct:
        sys.exit("ERROR: az CLI is not logged in.\n"
                 "  Run ./check_env.sh (service principal login) or az login.")
    return acct.get("name", "?")


def norm(name):
    """Normalise a model name for matching against quota names.

    The catalog says "gpt-4.1" where the quota list says "gpt4.1". Dropping
    hyphens makes both sides agree without a hand-maintained mapping.
    """
    return name.lower().replace("-", "")


def parse_date(value):
    """ISO date string -> date, or None."""
    if not value:
        return None
    try:
        return datetime.date.fromisoformat(value[:10])
    except ValueError:
        return None


# ==============================================================================
# Catalog and quota
# ==============================================================================

def catalog(location, sku):
    """Every chat model offered in this location with this SKU.

    Returns:
        List of dicts: format, name, version, lifecycle, retires, default.
    """
    data = az_json(["cognitiveservices", "model", "list",
                    "--location", location])
    if data is None:
        sys.exit("ERROR: could not read the model catalog for %s." % location)

    rows = {}
    for entry in data:
        m = entry.get("model") or {}
        # Chat only: embedding, image, audio and speech models cannot answer
        # a chat-completions probe and cannot drive an agent.
        if (m.get("capabilities") or {}).get("chatCompletion") != "true":
            continue
        # Rerank models are flagged chatCompletion in the catalog but only
        # score documents; every chat call to one is a 404.
        if "rerank" in (m.get("name") or "").lower():
            continue
        skus = [s for s in (m.get("skus") or []) if s.get("name") == sku]
        if not skus:
            continue
        # A SKU can be listed more than once with different retirement dates;
        # the latest one is what a new deployment gets.
        sku_retire = max((parse_date(s.get("deprecationDate")) for s in skus
                          if s.get("deprecationDate")), default=None)
        inference_retire = parse_date((m.get("deprecation") or {})
                                      .get("inference"))
        retires = min((d for d in (sku_retire, inference_retire) if d),
                      default=None)
        key = (m.get("format"), m.get("name"), m.get("version"))
        rows[key] = {
            "format": m.get("format") or "?",
            "name": m.get("name"),
            "version": m.get("version"),
            "lifecycle": m.get("lifecycleStatus") or "?",
            "retires": retires,
            "default": bool(m.get("isDefaultVersion")),
        }
    return sorted(rows.values(),
                  key=lambda r: (r["format"].lower(), r["name"].lower(),
                                 r["version"]))


def quota(location, sku):
    """Map normalised model name -> (used, limit) for this SKU.

    OpenAI models are metered as "OpenAI.<sku>.<name>", everything else as
    "AIServices.<sku>.<name>"; both are read.
    """
    data = az_json(["cognitiveservices", "usage", "list",
                    "--location", location]) or []
    out = {}
    for u in data:
        name = (u.get("name") or {}).get("value") or ""
        parts = name.split(".", 2)
        if len(parts) == 3 and parts[1] == sku:
            out[norm(parts[2])] = (u.get("currentValue") or 0,
                                   u.get("limit") or 0)
    return out


def verdict(row, q, capacity=None):
    """Classify one catalog row as ok / warn / gated / fail, with a reason."""
    today = datetime.date.today()
    if row["lifecycle"].lower() in ("deprecated", "retired"):
        return "fail", "lifecycle is %s" % row["lifecycle"]
    if row["retires"] and row["retires"] <= today:
        return "fail", "retired %s" % row["retires"]
    used, limit = q.get(norm(row["name"]), (None, None))
    if limit is not None and limit <= 0:
        return "fail", "quota limit is 0 for this subscription"
    if row["format"] in GATED_FORMATS:
        return "gated", "needs org details to deploy"
    if limit is None:
        # A handful of catalog models have no quota line at all. Only a
        # deploy says whether they work.
        return "warn", "no quota entry -- try --deploy"
    free = limit - used
    if capacity is not None and free < capacity:
        # Not a hard failure: on a redeploy our own deployment is part of
        # "used", so free quota legitimately looks short.
        return "warn", "only %d of %d free (want %d)" % (free, limit, capacity)
    if row["lifecycle"].lower() in ("legacy", "deprecating"):
        return "warn", "lifecycle is %s" % row["lifecycle"]
    if row["lifecycle"].lower() == "preview":
        # Many non-OpenAI models carry a 2099-12-31 placeholder date, so only
        # mention retirement when it is real and near.
        days = (row["retires"] - today).days if row["retires"] else None
        return "warn", "Preview" + (" -- retires in %d days" % days
                                    if days is not None and days < 365
                                    else "")
    if row["retires"] and (row["retires"] - today).days < 90:
        return "warn", "retires in %d days" % (row["retires"] - today).days
    return "ok", ""


# ==============================================================================
# Account, deployments, calls
# ==============================================================================

def az_retry(args, attempts=3):
    """az() with a short retry, for reads that must not fail silently.

    Several az processes sharing one login cache (two probes at once, say)
    can make an individual call fail transiently. Retrying clears that; a
    failure that persists is returned so the caller can report it.
    """
    ok, data = False, None
    for i in range(attempts):
        ok, data = az(args)
        if ok:
            break
        time.sleep(3 * (i + 1))
    return ok, data


def find_account():
    """Locate the openclaw account.

    Returns:
        ((name, foundry_base_url, key), None) when found, or
        (None, reason) -- where reason distinguishes "no account" from an
        az error, which used to be reported as a missing account.
    """
    ok, accounts = az_retry(["cognitiveservices", "account", "list",
                             "--resource-group", CORE_RG])
    if not ok:
        return None, "az could not list accounts in %s: %s" % (CORE_RG,
                                                               accounts)
    for a in accounts or []:
        if not a.get("name", "").startswith(ACCOUNT_PREFIX):
            continue
        ok, keys = az_retry(["cognitiveservices", "account", "keys", "list",
                             "--name", a["name"], "--resource-group", CORE_RG])
        if not ok or not keys:
            return None, "found %s but could not read its keys: %s" % (
                a["name"], keys)
        props = a.get("properties") or {}
        base = (props.get("endpoints") or {}).get("AI Foundry API") \
            or "https://%s.services.ai.azure.com/" % a["name"]
        return (a["name"], base, keys.get("key1")), None
    return None, ("no %s* account in %s -- apply 01-core to time deployments"
                  " or use --deploy" % (ACCOUNT_PREFIX, CORE_RG))


def deployments(account):
    """Deployment name -> (format, model, version) for the account."""
    data = az_json(["cognitiveservices", "account", "deployment", "list",
                    "--name", account, "--resource-group", CORE_RG]) or []
    out = {}
    for d in data:
        m = ((d.get("properties") or {}).get("model") or {})
        out[d.get("name")] = (m.get("format"), m.get("name"), m.get("version"))
    return out


def create_deployment(account, name, row, sku, capacity):
    """Create one temporary deployment. Returns (ok, error_text).

    Azure allows one deployment change per account at a time and answers
    "Another operation is being performed on the parent resource" to the
    rest -- which also happens briefly while the previous model's delete is
    still settling. That is a wait-and-retry, not a model failure.
    """
    err = None
    for attempt in range(6):
        ok, err = az(["cognitiveservices", "account", "deployment", "create",
                      "--name", account, "--resource-group", CORE_RG,
                      "--deployment-name", name,
                      "--model-name", row["name"],
                      "--model-version", row["version"],
                      "--model-format", row["format"],
                      "--sku-name", sku, "--sku-capacity", str(capacity)],
                     timeout=900)
        if ok:
            return True, None
        if "Another operation is being performed" not in (err or ""):
            break
        time.sleep(10 * (attempt + 1))
    return False, err


def delete_deployment(account, name):
    az(["cognitiveservices", "account", "deployment", "delete",
        "--name", account, "--resource-group", CORE_RG,
        "--deployment-name", name], timeout=600)


def post(url, key, body, timeout=120):
    """POST JSON; return (status, parsed_or_text, retry_after_seconds)."""
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                 method="POST")
    req.add_header("api-key", key)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8",
                                                              "replace")), 0
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        retry = exc.headers.get("retry-after") or "0"
        try:
            return exc.code, json.loads(raw), int(float(retry))
        except ValueError:
            return exc.code, raw, 0
    except Exception as exc:                       # timeouts, DNS, TLS
        return 0, "%s: %s" % (type(exc).__name__, exc), 0


def error_text(body):
    if isinstance(body, dict):
        err = body.get("error")
        if isinstance(err, dict):
            return err.get("message") or json.dumps(err)
        return json.dumps(body)
    return str(body)


def call(base, key, deployment, prompt, max_tokens, fresh=False):
    """One real chat call through the Foundry /openai/v1 route.

    Args:
        fresh: True for a just-created deployment, which can answer 404 or
            429 for a short while after provisioning reports success.
    """
    url = base.rstrip("/") + "/openai/v1/chat/completions"
    # max_completion_tokens first: the gpt-5 family rejects max_tokens. Some
    # non-OpenAI models reject max_completion_tokens instead, so fall back.
    # No temperature -- several reasoning models accept only the default.
    body = {"model": deployment,
            "messages": [{"role": "user", "content": prompt}],
            "max_completion_tokens": max_tokens}

    out = {"ok": False, "elapsed": 0.0, "error": None,
           "in_tok": None, "out_tok": None, "think_tok": None}
    deadline = time.time() + (120 if fresh else 30)
    while True:
        t0 = time.perf_counter()
        status, data, retry = post(url, key, body)
        out["elapsed"] = time.perf_counter() - t0
        if status == 400 and "max_completion_tokens" in body \
                and "max_completion_tokens" in error_text(data):
            body["max_tokens"] = body.pop("max_completion_tokens")
            continue
        if status in (404, 429) and time.time() < deadline:
            time.sleep(min(max(retry, 5), 20))
            continue
        break

    if status != 200 or not isinstance(data, dict):
        out["error"] = ("HTTP %s: %s" % (status, error_text(data)))[:90]
        return out

    usage = data.get("usage") or {}
    msg = ((data.get("choices") or [{}])[0].get("message") or {})
    out["ok"] = True
    out["in_tok"] = usage.get("prompt_tokens")
    out["out_tok"] = usage.get("completion_tokens")
    # Reasoning models spend hidden tokens before answering and bill them as
    # output -- usually why a trivial prompt is slow. OpenAI reports a count;
    # DeepSeek-style models return the text instead.
    out["think_tok"] = (usage.get("completion_tokens_details") or {}) \
        .get("reasoning_tokens") or (1 if msg.get("reasoning_content") else None)
    return out


def result_line(label, r):
    if r["ok"]:
        think = ""
        if r["think_tok"]:
            think = ("  think %4d" % r["think_tok"]) if r["think_tok"] > 1 \
                else "  think"
        return "  OK    %s %7.2fs  in %4s  out %4s%s" % (
            label, r["elapsed"], r["in_tok"], r["out_tok"], think)
    return "  FAIL  %s %7.2fs  %s" % (label, r["elapsed"], r["error"])


def temp_name(row):
    """Deployment name for a temporary probe deployment (max 64 chars)."""
    slug = re.sub(r"[^A-Za-z0-9-]", "-", row["name"]).strip("-").lower()
    return (TEMP_PREFIX + slug)[:64]


# ==============================================================================
# Main
# ==============================================================================

def take_value(args, flag, cast, example):
    """Remove "flag value" from args and return value, or None if absent."""
    if flag not in args:
        return None
    i = args.index(flag)
    try:
        value = cast(args[i + 1])
    except (IndexError, ValueError):
        sys.exit("ERROR: %s needs a value, e.g. %s %s" % (flag, flag, example))
    del args[i:i + 2]
    return value


def take_flag(args, flag):
    if flag in args:
        args.remove(flag)
        return True
    return False


def main():
    args = sys.argv[1:]

    # Must match AZURE_LOCATION / AZURE_SKU in azure-config.sh. Availability
    # and quota are per region and per SKU, so checking any other pair proves
    # nothing about the deploy.
    location = take_value(args, "--location", str, "westus3") or "eastus"
    sku = take_value(args, "--sku", str, "DataZoneStandard") or \
        "GlobalStandard"
    max_tokens = take_value(args, "--tokens", int, "800") or 16
    live = not take_flag(args, "--no-live")
    deploy = take_flag(args, "--deploy")

    prompt = "Reply with OK."
    if max_tokens > 50:
        # A one-word prompt with a big cap just stops early; give it something
        # it will keep writing about so the timing means something.
        prompt = ("Write a short paragraph explaining what a resume is, "
                  "in plain language.")

    check_mode = len(args) >= 2 and args[0] == "--check"
    filters = [] if check_mode else [a.lower() for a in args]

    sub = subscription()
    rows = catalog(location, sku)
    q = quota(location, sku)

    # --------------------------------------------------------------------------
    # --check model:version[:capacity]
    # --------------------------------------------------------------------------
    if check_mode:
        parts = args[1].split(":")
        if len(parts) < 2:
            sys.exit("ERROR: --check needs model:version, e.g. "
                     "gpt-4.1:2025-04-14")
        name, version = parts[0], parts[1]
        capacity = int(parts[2]) if len(parts) > 2 and parts[2] else None
        match = [r for r in rows if r["name"] == name
                 and r["version"] == version]
        if not match:
            versions = [r["version"] for r in rows if r["name"] == name]
            hint = (" -- offered versions: %s" % ", ".join(versions)
                    if versions else " -- no chat model by that name here")
            print("FAIL: %s:%s not in the %s catalog for %s%s"
                  % (name, version, sku, location, hint))
            return 1
        row = match[0]
        level, reason = verdict(row, q, capacity)
        if level in ("fail", "gated"):
            print("FAIL: %s:%s in %s -- %s" % (name, version, location, reason))
            return 1
        retires = row["retires"] or "no date"
        extra = (" (WARNING: %s)" % reason) if level == "warn" else ""
        print("OK: %s:%s (%s) deployable in %s as %s, retires %s%s"
              % (name, version, row["format"], location, sku, retires, extra))
        return 0

    # --------------------------------------------------------------------------
    # Catalog report
    # --------------------------------------------------------------------------
    print("subscription : %s" % sub)
    print("location     : %s" % location)
    print("sku          : %s" % sku)
    print("filters      : %s\n"
          % (filters or "(none -- every chat model in the catalog)"))

    if filters:
        rows = [r for r in rows
                if any(f in (r["name"] + " " + r["format"]).lower()
                       for f in filters)]
    if not rows:
        print("No chat models matched.")
        return 1

    print("Catalog (%d model versions, %d providers):\n"
          % (len(rows), len({r["format"] for r in rows})))
    print("  %-5s %-11s %-32s %-12s %-19s %-11s %s"
          % ("", "PROVIDER", "MODEL", "VERSION", "LIFECYCLE", "RETIRES",
             "QUOTA FREE"))
    flags = {"ok": "OK", "warn": "WARN", "gated": "GATED", "fail": "NO"}
    for r in rows:
        level, reason = verdict(r, q)
        used, limit = q.get(norm(r["name"]), (None, None))
        free = ("%d/%d" % (limit - used, limit)) if limit is not None else "-"
        print("  %-5s %-11s %-32s %-12s %-19s %-11s %s%s"
              % (flags[level], r["format"][:11], r["name"][:32],
                 r["version"][:12], r["lifecycle"], r["retires"] or "-",
                 free, ("  " + reason) if reason else ""))

    print()
    print("OK = deployable. WARN = deployable but Legacy, Preview, retiring")
    print("within 90 days, short on quota, or with no quota entry. GATED =")
    print("needs your organization details to deploy (Claude). NO = cannot")
    print("be deployed here.")
    print()
    print("Any non-GATED model can go in AZURE_MODELS (add the provider as")
    print("the 6th field for non-OpenAI ones). --deploy proves a model")
    print("answers before you commit to it.")

    if not live and not deploy:
        return 0

    print()
    acct, reason = find_account()
    if not acct:
        print("Live: %s" % reason)
        print("Catalog results above still apply.")
        # An az error is a failure; a genuinely absent account is not.
        return 1 if reason.startswith(("az could not", "found ")) else 0
    account, base, key = acct
    existing = deployments(account)

    # --------------------------------------------------------------------------
    # Live: deployments that already exist
    # --------------------------------------------------------------------------
    results = []
    if live:
        deps = {d: m for d, m in existing.items()
                if not d.startswith(TEMP_PREFIX)
                and (not filters or any(f in (d + " ".join(filter(None, m)))
                                        .lower() for f in filters))}
        if deps:
            print("Live: %d existing deployment(s) in %s, max_tokens %d\n"
                  % (len(deps), account, max_tokens))
            # The first call carries TLS and connection setup, so it reads
            # high. Absorb it rather than penalising whichever sorts first.
            if len(deps) > 1:
                t0 = time.perf_counter()
                call(base, key, sorted(deps)[0], "Hi", 16)
                print("  warm-up  %7.2fs  (discarded)\n"
                      % (time.perf_counter() - t0))
            for dep in sorted(deps):
                fmt, model, version = deps[dep]
                r = call(base, key, dep, prompt, max_tokens)
                print(result_line("%-11s %-32s" % ((fmt or "?")[:11],
                                                   "%s:%s" % (model, version)),
                                  r))
                results.append(("%s (deployed as %s)" % (model, dep), r))
            print()

    # --------------------------------------------------------------------------
    # Deploy: temporary deployment per catalog model
    # --------------------------------------------------------------------------
    if deploy:
        # Two --deploy runs on one account collide: Azure serialises
        # deployment changes, and each run deletes the other's probe-tmp-*
        # deployments as "leftovers". Refuse to start a second one here.
        lock = open(os.path.join("/tmp", "probe_azure-%s.lock" % account), "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Deploy: another probe_azure.py --deploy is already running"
                  " against %s." % account)
            print("Wait for it to finish; running both makes each fail.")
            return 1

        # Leftovers from an interrupted run cost quota; clear them first.
        stale = [d for d in existing if d.startswith(TEMP_PREFIX)]
        for d in stale:
            print("Deploy: removing leftover %s" % d)
            delete_deployment(account, d)

        deployed_models = {(m[1], m[2]) for d, m in existing.items()
                           if not d.startswith(TEMP_PREFIX)}
        # One version per model: the catalog default, else the newest.
        by_name = {}
        for r in rows:
            cur = by_name.get((r["format"], r["name"]))
            if cur is None or (r["default"] and not cur["default"]) or \
                    (r["default"] == cur["default"]
                     and r["version"] > cur["version"]):
                by_name[(r["format"], r["name"])] = r
        todo, skipped = [], []
        for r in sorted(by_name.values(),
                        key=lambda r: (r["format"].lower(), r["name"].lower())):
            level, reason = verdict(r, q)
            if (r["name"], r["version"]) in deployed_models and live:
                continue                   # already timed above
            if level in ("fail", "gated"):
                skipped.append((r, reason))
                continue
            todo.append(r)

        print("Deploy: %d model(s) to test in %s, one at a time, %d capacity"
              " each." % (len(todo), account, TEMP_CAPACITY))
        print("Each is a real deployment -- expect 10-30 seconds per"
              " model.\n")
        for r, reason in skipped:
            print("  SKIP  %-11s %-32s %s" % (r["format"][:11],
                                              "%s:%s" % (r["name"],
                                                         r["version"]),
                                              reason))
        if skipped:
            print()

        for i, r in enumerate(todo, 1):
            name = temp_name(r)
            label = "%-11s %-32s" % (r["format"][:11],
                                     "%s:%s" % (r["name"], r["version"]))
            used, limit = q.get(norm(r["name"]), (0, None))
            capacity = TEMP_CAPACITY if limit is None else \
                max(1, min(TEMP_CAPACITY, int(limit - used)))
            t0 = time.perf_counter()
            try:
                ok, err = create_deployment(account, name, r, sku, capacity)
                if not ok:
                    print("  FAIL  %s %7.2fs  deploy: %s"
                          % (label, time.perf_counter() - t0, (err or "")[:80]))
                    continue
                res = call(base, key, name, prompt, max_tokens, fresh=True)
                print(result_line(label, res) + "   [%d/%d]" % (i, len(todo)))
                results.append(("%s:%s" % (r["name"], r["version"]), res))
            finally:
                # Always remove it, even on Ctrl-C mid-call; a leftover costs
                # quota and is also caught at the start of the next run.
                delete_deployment(account, name)
        print()

    # --------------------------------------------------------------------------
    # Ranking
    # --------------------------------------------------------------------------
    working = sorted(((n, r) for n, r in results if r["ok"]),
                     key=lambda pair: pair[1]["elapsed"])
    if not results:
        return 0
    if not working:
        print("Nothing answered.")
        return 1

    print("Answered (%d of %d, %d max_tokens, fastest first):"
          % (len(working), len(results), max_tokens))
    for n, r in working:
        out_tok = r["out_tok"] or 0
        rate = ("  %6.1f tok/s" % (out_tok / r["elapsed"])
                if out_tok and r["elapsed"] > 0 else "")
        print("  %7.2fs  %-44s%s" % (r["elapsed"], n, rate))
    print()
    print("Timings RANK models against each other -- they are not a")
    print("throughput measure. Re-run with --tokens 800 for something closer")
    print("to the length an agent turn actually generates.")
    if any(r["think_tok"] for _, r in working):
        print()
        print("A 'think' column means the model reasoned before answering;")
        print("those tokens are billed as output, so they cost time and money.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
