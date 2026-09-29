# CLAUDE.md — azure-openclaw

## Project Overview

Terraform + Packer project that deploys an Azure VM running **OpenClaw**
(an AI coding agent) backed by **LiteLLM proxy** pointed at **Azure OpenAI**.
Users RDP into an LXQt desktop and access the OpenClaw web UI at
`http://localhost:18789` in Chrome. The Azure OpenAI models come from
`azure-config.sh` (GPT-4.1 primary, plus GPT-4.1 Nano, GPT-6 Sol and GPT-5.4
Mini by default). RDP (3389) and SSH (22) are both open from anywhere on
`openclaw-nsg`.

The README architecture diagram is generated: edit `make_diagram.py` and run
`python make_diagram.py`, which rewrites `architecture-{light,dark}.svg`. It
reads the model names from `azure-config.sh`. Keep it in step with
aws-openclaw's `make_diagram.py`, which it was copied from.

## Architecture

```
01-core/          VNet + subnet + NSG + NAT gateway + Key Vault + Azure OpenAI + ACS Email
02-packer/        Packer build: Ubuntu 24.04 → openclaw_image (azure-arm)
  scripts/        01-packages through 14-apache
  files/          litellm/openclaw-gateway/xvfb services, openclaw.png
03-openclaw/      Azure VM + managed identity + RBAC + Key Vault secrets
                  (openclaw-credentials, ubuntu-credentials)
  scripts/
    custom_data.sh  Boot: retrieve password from Key Vault, write litellm config,
                    configure email, start systemd services, register models
azure-config.sh   Single source of truth for the model list
probe_azure.py    Reports which models this subscription can deploy (and, once
                  deployed, how fast they answer)
```

### Deployment Order

1. `01-core` — VNet, Key Vault, Azure OpenAI (one deployment per model in
   `azure-config.sh`), ACS Email
2. `02-packer` — Packer builds `openclaw_image` (azure-arm)
3. `03-openclaw` — Azure VM from `openclaw_image`, managed identity, RBAC

### Key Resources

| Resource | Value |
|---|---|
| Region | `East US` |
| VNet / CIDR | `openclaw-vnet` / `10.0.0.0/23` |
| VM name | `openclaw-host` |
| VM size | `Standard_D4s_v3` (variable) |
| LiteLLM port | `4000` |
| LiteLLM master key | `sk-openclaw` |
| OpenClaw gateway port | `18789` (loopback only) |
| Azure OpenAI models | From `azure-config.sh`; `gpt-4.1` (primary), `gpt-4.1-nano`, `gpt-6-sol`, `gpt-5.4-mini` by default |
| Linux user | `openclaw` (sudo, NOPASSWD) |
| Password source | Azure Key Vault secret `openclaw-credentials` |
| Admin user | `ubuntu` (VM admin, SSH password auth on); Key Vault secret `ubuntu-credentials` |

## Common Commands

```bash
# Validate environment: CLI tools, ARM_* vars, Azure login, and every model in
# azure-config.sh being deployable
./check_env.sh

# Deploy everything (01-core → 02-packer → 03-openclaw → validate)
./apply.sh

# Tear down (03-openclaw → delete images → 01-core)
./destroy.sh

# Print connection details, including the password
./validate.sh

# See which models this subscription can deploy (and live latency once deployed)
./probe_azure.py
```

### Getting the openclaw User Password

```bash
VAULT=$(az keyvault list \
  --resource-group openclaw-core-rg \
  --query "[0].name" --output tsv)

az keyvault secret show \
  --vault-name "$VAULT" \
  --name openclaw-credentials \
  --query value --output tsv | jq -r '.password'
```

## What Packer (02-packer) Does

Builds `openclaw_image` from Ubuntu 24.04 (azure-arm, fully self-contained):

| Script | What it installs |
|---|---|
| `01-packages.sh` | apt retry helper, removes snap, installs base packages |
| `02-desktop.sh` | LXQt desktop environment |
| `03-xrdp.sh` | XRDP + LXQt session configuration |
| `04-chrome.sh` | Google Chrome Stable, with the real sandbox (no `--no-sandbox`) |
| `05-tools.sh` | Git, AWS CLI v2, Terraform, Packer, Azure CLI, gcloud, VS Code |
| `06-user.sh` | `openclaw` Linux user with passwordless sudo |
| `07-node.sh` | Node.js 22, OpenClaw, `openclaw-dashboard` desktop launcher |
| `08-litellm.sh` | LiteLLM proxy in Python venv at `/opt/litellm-venv` |
| `11-python-tools.sh` | Pinned Python packages, system utilities, and azure-communication-email SDK |
| `12-onlyoffice.sh` | OnlyOffice Desktop Editors |
| `13-azure-tools.sh` | `azure-cost-report` and `send-cost-report` helper scripts |
| `14-apache.sh` | Apache2 serving world-writable `/var/www/html` on loopback |
| `09-openclaw-init.sh` | Stamps gateway config; writes `HEARTBEAT.md`/`SYSTEM.md` |
| `10-services.sh` | Installs and enables the systemd units |

Note the provisioner order is not the filename order: `09` and `10` run last,
because the gateway must be stamped after everything it advertises exists.

Every build script installs through `apt-install-retry` (created by
`01-packages.sh`), not `apt-get install`. `security.ubuntu.com` servers are
briefly out of step while a security update publishes, which surfaces as a
random `404 Not Found`; the helper re-reads the index and retries. Use it in
any new build script.

Email and `send-cost-report` are deliberately absent from the image's agent
notes. `custom_data.sh` appends them to `HEARTBEAT.md` and `SYSTEM.md` only
when the `openclaw-email-config` secret exists.

## What custom_data.sh Does

Runs at first boot on the Azure VM:

1. Logs in with managed identity (`az login --identity`)
2. Reads `openclaw-credentials` from Key Vault → sets `openclaw` Linux user password
3. Reads `openclaw-openai-config` from Key Vault → renders
   `/opt/openclaw/litellm-config.yaml`, one `model_list` entry per model in
   `azure-config.sh`
4. Reads `openclaw-email-config` from Key Vault → configures `acs-mail`
   (plain text or HTML, no attachments) and adds Email to the agent's
   workspace notes. The script treats the secret as optional, but `01-core`
   always creates it
5. Starts `litellm.service` and `openclaw-gateway.service`
6. Registers every model with OpenClaw, sets the primary, and restarts the
   gateway

The OpenAI API key and ACS connection string end up on disk under
`/opt/openclaw` (LiteLLM config, `email-config.json`). The managed identity
covers only Key Vault and Cost Management.

## Model Configuration

`azure-config.sh` is the single source of truth. It defines an `AZURE_MODELS`
array of `alias|model|version|capacity|display[|format]` (format defaults to
`OpenAI`), plus `AZURE_PRIMARY`,
`AZURE_SKU` and `AZURE_LOCATION`, and exports them to Terraform as
`TF_VAR_models`, `TF_VAR_primary_alias`, `TF_VAR_deployment_sku` and
`TF_VAR_location`.

Everything derives from that one array: the Azure OpenAI deployments in
`01-core/ai.tf` (one per entry, named after the alias), the LiteLLM
`model_list` and the OpenClaw model picker (both rendered by
`custom_data.sh`), and the `check_env.sh` pre-flight.

**Why aliases.** The alias is the deployment name, what LiteLLM routes on,
and what OpenClaw stores as the model ID. Bumping a version behind an alias
updates the deployment in place and does not repoint agents.

**Why the probe.** Azure models must be deployed before they can be called,
and a catalog entry can still fail to deploy: wrong version, SKU not offered
in the region, retired, or zero quota. `check_env.sh` runs
`probe_azure.py --check model:version:capacity` on every entry before
anything is built; it reads the catalog and quota, so it needs no deployment.
Run `./probe_azure.py` to see every chat model the subscription offers (all
providers) -- and, once `01-core` exists, live latency for each deployment.
`--deploy` creates a temporary `probe-tmp-*` deployment per matching model,
calls it, and deletes it; leftovers from an interrupted run are removed at
the start of the next one.

All probe calls use the account's Foundry route,
`https://<account>.services.ai.azure.com/openai/v1/chat/completions` with the
deployment name as `model`. Verified 2026-09-24 for OpenAI and non-OpenAI
deployments alike.

**Two LiteLLM routes, chosen by format** (in `custom_data.sh`):

| Format | LiteLLM model | api_base |
|---|---|---|
| `OpenAI` | `azure/<alias>` | Cognitive Services endpoint + `api_version` |
| anything else | `openai/<alias>` | `https://<account>.services.ai.azure.com/openai/v1` |

The Foundry endpoint is stored in the `openclaw-openai-config` secret as
`foundry_endpoint`; `custom_data.sh` derives it from `endpoint` if an older
secret lacks it. The account key works there as a bearer token (verified).

Anthropic models need "model provider data" (industry, organization name,
country code) to deploy, so the probe marks them GATED, `--check` rejects
them, and `--deploy` skips them.

DeepSeek V4 Flash/Pro deploy (format `DeepSeek`, via the `openai/` route) but
are left out of `azure-config.sh`: their quota is 20K tokens per minute, too
small for a single agent turn.

`gpt-6-sol` and `gpt-5.4-mini` are in the default list but not yet verified
to drive OpenClaw tool calls.

`gpt-4.1` (the primary) and `gpt-4.1-nano` are *Legacy* and retire
2027-04-14.

## RBAC Permissions

The VM managed identity has:

| Role | Scope | Purpose |
|---|---|---|
| Key Vault Secrets User | Key Vault | Read credentials + OpenAI config at boot |
| Cost Management Reader | Subscription | Azure cost queries |

## Networking Design

- `openclaw-vnet` (10.0.0.0/23) — single VNet
- `vm-subnet` (10.0.0.0/25) — VM subnet, egress via NAT gateway
- NSG `openclaw-nsg` — ports 3389 (`Allow-RDP`) and 22 (`Allow-SSH`) inbound
  from `*`, all outbound allowed
- NAT Gateway — stable egress IP for API calls and package updates
- Public IP on VM — direct RDP access
- Apache listens on 80 but no NSG rule opens it — deliberately loopback only,
  for showing pages on the desktop

## Password Format

Generated by Terraform in `03-openclaw/accounts.tf`:

```
<word>-<6-digit-number>   e.g. "rocket-482910"
```

Stored in Key Vault as `{"username": "openclaw", "password": "..."}`.
