#!/bin/bash
# ================================================================================
# custom_data.sh — OpenClaw First-Boot Script (Azure)
#
# Terraform templatefile variables:
#   ${vault_name}  — Azure Key Vault name (from 01-core)
#
# Runs at first boot on the openclaw_image VM:
#   1. Login with managed identity
#   2. Read openclaw-credentials from Key Vault → set Linux user password
#   3. Read openclaw-openai-config from Key Vault → write litellm-config.yaml
#   4. Read openclaw-email-config from Key Vault (optional) → configure acs-mail
#   5. Start litellm and openclaw-gateway services
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
GPT4O_DEPLOYMENT=$(echo "$openai_config" | jq -r '.gpt4o_deployment')
GPT4O_MINI_DEPLOYMENT=$(echo "$openai_config" | jq -r '.gpt4o_mini_deployment')

echo "NOTE: [litellm] writing config"
cat > /opt/openclaw/litellm-config.yaml <<LITELLM
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: azure/$${GPT4O_DEPLOYMENT}
      api_base: $${OPENAI_ENDPOINT}
      api_version: "$${OPENAI_API_VERSION}"
      api_key: $${OPENAI_API_KEY}

  - model_name: gpt-4o-mini
    litellm_params:
      model: azure/$${GPT4O_MINI_DEPLOYMENT}
      api_base: $${OPENAI_ENDPOINT}
      api_version: "$${OPENAI_API_VERSION}"
      api_key: $${OPENAI_API_KEY}

litellm_settings:
  drop_params: true

general_settings:
  master_key: "sk-openclaw"
  drop_params: true
  max_tokens: 4096
  set_verbose: true
LITELLM
chown openclaw:openclaw /opt/openclaw/litellm-config.yaml
echo "NOTE: [litellm] config written"


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

    with open("/opt/openclaw/email-config.json") as f:
        config = json.load(f)

    from azure.communication.email import EmailClient
    client = EmailClient.from_connection_string(config["connection_string"])

    message = {
        "senderAddress": config["from_address"],
        "recipients": {"to": [{"address": args.to}]},
        "content": {"subject": args.subject, "plainText": body},
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
  chown -R openclaw:openclaw /home/openclaw/.openclaw/agents/main/workspace
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

echo "NOTE: [services] done"

echo "NOTE: custom-data complete: $(date -Is)"
