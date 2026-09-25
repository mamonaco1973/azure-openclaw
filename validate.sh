#!/bin/bash
# ================================================================================
# validate.sh
# ================================================================================
#
# Purpose:
#   Post-deploy validation for the OpenClaw AI Agent Workstation on Azure.
#   Reads Terraform outputs and prints connection details.
#
# ================================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/03-openclaw"

cd "${TF_DIR}"

PUBLIC_IP="$(terraform output -raw public_ip       2>/dev/null || echo '<not found>')"
PUBLIC_FQDN="$(terraform output -raw public_fqdn   2>/dev/null || echo '<not found>')"
VAULT_NAME="$(terraform output -raw vault_name     2>/dev/null || true)"
SECRET_ID="$(terraform output -raw credentials_secret_id 2>/dev/null || echo 'openclaw-credentials')"

# With no state, terraform output prints nothing and still exits 0, so the
# fallbacks above never fire. Apply them to empty values too.
PUBLIC_IP="${PUBLIC_IP:-<not found>}"
PUBLIC_FQDN="${PUBLIC_FQDN:-<not found>}"
SECRET_ID="${SECRET_ID:-openclaw-credentials}"

# The vault name has a random suffix, so fall back to finding it in the core
# resource group if the output is unavailable.
if [ -z "${VAULT_NAME}" ]; then
  VAULT_NAME="$(az keyvault list --resource-group openclaw-core-rg \
    --query "[?starts_with(name, 'openclaw-vault')].name | [0]" \
    --output tsv 2>/dev/null || true)"
fi

# Print the password outright rather than sending the operator off to look
# it up. Key Vault stays the source of truth; this just reads it back.
CREDS_JSON=""
if [ -n "${VAULT_NAME}" ]; then
  CREDS_JSON="$(az keyvault secret show \
    --vault-name "${VAULT_NAME}" \
    --name "${SECRET_ID}" \
    --query value \
    --output tsv 2>/dev/null || true)"
fi
if [ -n "${CREDS_JSON}" ]; then
  PASSWORD="$(printf '%s' "${CREDS_JSON}" | jq -r '.password')"
else
  # Usually means the caller lacks Key Vault Secrets User/Officer on the
  # vault, or the deploy has not finished. Fall back to the lookup command.
  PASSWORD="<unavailable> - run: az keyvault secret show --vault-name ${VAULT_NAME:-<vault>} --name ${SECRET_ID} --query value -o tsv | jq -r .password"
fi

echo ""
echo "==================================================="
echo "OpenClaw AI Agent Workstation - Quick Start (Azure)"
echo "==================================================="
echo ""

printf "%-28s %s\n" "NOTE: Public IP:"             "${PUBLIC_IP}"
printf "%-28s %s\n" "NOTE: Public FQDN:"           "${PUBLIC_FQDN}"
echo ""
printf "%-28s %s\n" "NOTE: RDP Host:"              "${PUBLIC_IP}:3389"
printf "%-28s %s\n" "NOTE: Username:"              "openclaw"
printf "%-28s %s\n" "NOTE: Password:"              "${PASSWORD}"
echo ""
