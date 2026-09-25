#!/bin/bash
# ================================================================================
# custom_data.sh — OpenClaw First-Boot Script (Azure)
#
# Terraform templatefile variables:
#   vault_name     — Azure Key Vault name (from 01-core)
#   models         — model list from azure-config.sh (alias = deployment name)
#   models_b64     — the same list, base64 JSON, for the OpenClaw CLI
#   primary_alias  — alias agents default to
#
# Runs at first boot on the openclaw_image VM:
#   1. Login with managed identity
#   2. Read openclaw-credentials from Key Vault → set Linux user password
#   3. Read openclaw-openai-config from Key Vault → write litellm-config.yaml
#   4. Read openclaw-email-config from Key Vault (optional) → configure acs-mail
#   5. Start litellm and openclaw-gateway services
#   6. Register the model list and primary with OpenClaw
# ================================================================================

set -euo pipefail

LOG=/root/custom_data.log
mkdir -p /root
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG" | logger -t custom-data -s 2>/dev/console) 2>&1
trap 'echo "ERROR at line $LINENO"; exit 1' ERR

echo "NOTE: custom-data start: $(date -Is)"

VAULT_NAME="${vault_name}"


# ================================================================================
# Azure Login (managed identity)
# ================================================================================

echo "NOTE: [auth] logging in with managed identity"
az login --identity --allow-no-subscriptions > /dev/null 2>&1
sudo -u openclaw az login --identity --allow-no-subscriptions > /dev/null 2>&1

SUBSCRIPTION_ID=$(az account list --query "[?state=='Enabled'] | [0].id" -o tsv 2>/dev/null || true)
if [ -n "$SUBSCRIPTION_ID" ]; then
  az account set --subscription "$SUBSCRIPTION_ID" > /dev/null 2>&1 || true
  sudo -u openclaw az account set --subscription "$SUBSCRIPTION_ID" > /dev/null 2>&1 || true
  echo "NOTE: [auth] subscription set: $${SUBSCRIPTION_ID}"
else
  echo "NOTE: [auth] no subscription found, continuing without subscription context"
fi
echo "NOTE: [auth] done"


# ================================================================================
# Credentials
# ================================================================================

echo "NOTE: [credentials] reading openclaw-credentials from Key Vault"
secret=$(az keyvault secret show \
  --name openclaw-credentials \
  --vault-name "$VAULT_NAME" \
  --query value \
  --output tsv)

OPENCLAW_PASSWORD=$(echo "$secret" | jq -r '.password')

echo "NOTE: [credentials] setting openclaw user password"
echo "openclaw:$${OPENCLAW_PASSWORD}" | chpasswd
echo "NOTE: [credentials] done"


# ================================================================================
# LiteLLM Config (Azure OpenAI)
# ================================================================================

echo "NOTE: [litellm] reading Azure OpenAI config from Key Vault"
openai_config=$(az keyvault secret show \
  --name openclaw-openai-config \
  --vault-name "$VAULT_NAME" \
  --query value \
  --output tsv)

OPENAI_ENDPOINT=$(echo "$openai_config" | jq -r '.endpoint')
OPENAI_API_KEY=$(echo "$openai_config" | jq -r '.api_key')
OPENAI_API_VERSION=$(echo "$openai_config" | jq -r '.api_version')

# Foundry endpoint for non-OpenAI models. Older secrets predate the field, so
# derive it from the Cognitive Services endpoint -- same subdomain, different
# host.
FOUNDRY_ENDPOINT=$(echo "$openai_config" | jq -r '.foundry_endpoint // empty')
if [ -z "$FOUNDRY_ENDPOINT" ]; then
  FOUNDRY_ENDPOINT=$(echo "$OPENAI_ENDPOINT" \
    | sed 's#cognitiveservices\.azure\.com#services.ai.azure.com#')
fi
FOUNDRY_ENDPOINT="$${FOUNDRY_ENDPOINT%/}"

# One entry per model in azure-config.sh. 01-core named each deployment after
# its alias, so the alias is both what OpenClaw asks for and the deployment
# LiteLLM calls.
#
# OpenAI models go through LiteLLM's azure provider. Everything else
# (DeepSeek, Meta, Mistral, ...) goes through its plain openai provider at the
# Foundry /openai/v1 route, where the deployment name is the model and the
# account key works as a bearer token.
echo "NOTE: [litellm] writing config"
cat > /opt/openclaw/litellm-config.yaml <<LITELLM
model_list:
%{ for m in models ~}
  - model_name: ${m.alias}
    litellm_params:
%{ if m.format == "OpenAI" ~}
      model: azure/${m.alias}
      api_base: $${OPENAI_ENDPOINT}
      api_version: "$${OPENAI_API_VERSION}"
%{ else ~}
      model: openai/${m.alias}
      api_base: $${FOUNDRY_ENDPOINT}/openai/v1
%{ endif ~}
      api_key: $${OPENAI_API_KEY}
%{ endfor ~}

litellm_settings:
  drop_params: true

general_settings:
  master_key: "sk-openclaw"
  drop_params: true
  max_tokens: 4096
  set_verbose: true
LITELLM
chown openclaw:openclaw /opt/openclaw/litellm-config.yaml
echo "NOTE: [litellm] config written for these models:"
grep '^  - model_name:' /opt/openclaw/litellm-config.yaml


# ================================================================================
# Email (Azure Communication Services — optional)
# ================================================================================

echo "NOTE: [email] reading email config from Key Vault"
email_config=$(az keyvault secret show \
  --name openclaw-email-config \
  --vault-name "$VAULT_NAME" \
  --query value \
  --output tsv 2>/dev/null || echo "{}")

ACS_CONNECTION=$(echo "$email_config" | jq -r '.connection_string // empty')
ACS_FROM=$(echo "$email_config" | jq -r '.from_address // empty')

if [ -n "$ACS_CONNECTION" ]; then
  echo "NOTE: [email] configuring ACS email sender"

  # Write email config file (readable by openclaw user only)
  cat > /opt/openclaw/email-config.json <<EOF
{
  "connection_string": "$${ACS_CONNECTION}",
  "from_address": "$${ACS_FROM}"
}
EOF
  chmod 600 /opt/openclaw/email-config.json
  chown openclaw:openclaw /opt/openclaw/email-config.json

  # Write acs-mail Python wrapper
  cat > /usr/local/bin/acs-mail <<'PYMAIL'
#!/usr/bin/env python3
"""Send email via Azure Communication Services.

Usage:
  echo "Body" | acs-mail -s "Subject" -t recipient@example.com
  acs-mail -s "Subject" -t recipient@example.com "Body text"
"""
import sys
import json
import argparse

def main():
    parser = argparse.ArgumentParser(description="Send email via ACS")
    parser.add_argument("-s", "--subject", required=True, help="Email subject")
    parser.add_argument("-t", "--to", required=True, help="Recipient address")
    parser.add_argument("body", nargs="?", default=None, help="Email body")
    args = parser.parse_args()

    body = args.body if args.body else sys.stdin.read()
    is_html = body.strip().startswith("<")

    with open("/opt/openclaw/email-config.json") as f:
        config = json.load(f)

    from azure.communication.email import EmailClient
    client = EmailClient.from_connection_string(config["connection_string"])

    content = {"subject": args.subject, "html": body} if is_html else {"subject": args.subject, "plainText": body}
    message = {
        "senderAddress": config["from_address"],
        "recipients": {"to": [{"address": args.to}]},
        "content": content,
    }

    poller = client.begin_send(message)
    poller.result()
    print(f"Email sent to {args.to}")

if __name__ == "__main__":
    main()
PYMAIL
  chmod 755 /usr/local/bin/acs-mail

  # Write EMAIL.md to workspace
  mkdir -p /home/openclaw/.openclaw/agents/main/workspace
  cat > /home/openclaw/.openclaw/agents/main/workspace/EMAIL.md <<EOF
# Email Sending

Azure Communication Services is configured for outbound email.
Use the \`acs-mail\` command via exec to send email.

## Send a plain text email
\`\`\`bash
echo "Message body here" | acs-mail -s "Subject" -t recipient@example.com
\`\`\`

## Send with inline body
\`\`\`bash
acs-mail -s "Subject" -t recipient@example.com "Body text here"
\`\`\`

From address: $${ACS_FROM}
EOF
  # chown the whole tree, NOT just workspace/. This script runs as root, so
  # the mkdir -p above creates agents/ and agents/main/ root-owned too; a
  # chown that starts at workspace/ never reaches them, and the gateway
  # (running as openclaw) then fails with EACCES creating anything else
  # under agents/main -- e.g. the main agent's session storage.
  chown -R openclaw:openclaw /home/openclaw/.openclaw

  # The image's HEARTBEAT.md and SYSTEM.md say nothing about email or
  # send-cost-report, because both need this secret. Tell the agent only now
  # that the credentials are known to exist.
  echo "NOTE: [email] adding email to the agent's workspace notes"
  WORKSPACE=/home/openclaw/.openclaw/workspace
  mkdir -p "$${WORKSPACE}"
  cat >> "$${WORKSPACE}/HEARTBEAT.md" <<'NOTE'
- **Email**: `echo "body" | acs-mail -s "Subject" -t recipient@example.com`
- **Send Cost Report**: Run `send-cost-report <email>` via exec — generates an HTML cost report and emails it via ACS. Example: `send-cost-report user@example.com`
NOTE
  cat >> "$${WORKSPACE}/SYSTEM.md" <<NOTE

## Email
Azure Communication Services is configured. Use the \`acs-mail\` command --
the from address ($${ACS_FROM}) is pre-configured.

\`\`\`bash
# Plain text
echo "Body here" | acs-mail -s "Subject" -t recipient@example.com

# Email an HTML cost report
send-cost-report recipient@example.com
\`\`\`
NOTE
  chown -R openclaw:openclaw "$${WORKSPACE}"

  echo "NOTE: [email] done"
else
  echo "NOTE: [email] no ACS config found, skipping"
fi


# ================================================================================
# Start Services
# ================================================================================

echo "NOTE: [services] starting litellm"
systemctl start litellm

echo "NOTE: [services] starting openclaw-gateway"
systemctl restart openclaw-gateway

systemctl restart litellm
echo "NOTE: [services] waiting for litellm to be ready"
for i in $(seq 1 20); do
  if curl -s http://localhost:4000/health > /dev/null 2>&1; then
    echo "NOTE: [services] litellm ready after $((i * 3))s"
    break
  fi
  echo "NOTE: [services] litellm not ready yet (attempt $i/20)..."
  sleep 3
done


# ================================================================================
# OpenClaw Model Registration
# ================================================================================
#
# The image bakes in the models 09-openclaw-init.sh knew about. Replace that
# with the list from azure-config.sh, so the picker offers exactly what
# LiteLLM serves -- an alias the picker shows but LiteLLM lacks fails only
# when someone selects it.

echo "NOTE: [openclaw] registering models from azure-config.sh"

# Wait for the gateway to finish stamping its config
sleep 20

OPENCLAW_BIN=$(which openclaw)

# Decoded from base64 rather than interpolated as JSON: a display name
# containing an apostrophe would otherwise break out of the quoted string.
MODELS_JSON=$(echo '${models_b64}' | base64 -d | jq -c '.')
PRIMARY_ALIAS='${primary_alias}'

PROVIDER_JSON=$(jq -n --argjson models "$${MODELS_JSON}" '{
  baseUrl: "http://localhost:4000",
  apiKey:  "sk-openclaw",
  api:     "azure-openai-responses",
  models:  $models
}')

# "$@" is deliberate and must NOT be written "$$@". templatefile only treats
# $$ as an escape when a { follows it, so $$@ survives into the rendered
# script and bash reads it as $$ (the PID) plus a literal @.
run_openclaw() {
  sudo -u openclaw env HOME=/home/openclaw PATH="$${PATH}" \
    "$${OPENCLAW_BIN}" "$@"
}

if ! run_openclaw config set models.providers.litellm \
     "$${PROVIDER_JSON}" --strict-json; then
  echo "ERROR: [openclaw] failed to register the litellm provider - the"
  echo "ERROR: [openclaw] model picker will show whatever was baked in."
fi

run_openclaw config set agents.defaults.model.primary \
  "litellm/$${PRIMARY_ALIAS}"

echo "NOTE: [openclaw] restarting gateway to apply model config"
systemctl restart openclaw-gateway

echo "NOTE: [services] done"

echo "NOTE: custom-data complete: $(date -Is)"
