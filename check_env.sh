#!/bin/bash
# ==============================================================================
# check_env.sh - Environment Validation
# ------------------------------------------------------------------------------
# Purpose:
#   - Validates that required CLI tools are available in the current PATH.
#   - Verifies Azure CLI authentication and connectivity.
#   - Confirms ARM_* environment variables are set.
#   - Registers the Azure resource providers the deploy needs.
#   - Verifies every model in azure-config.sh can be deployed: offered in the
#     region with the SKU, not retired, and with quota available.
#
# Fast-Fail Behavior:
#   - Script exits immediately on command failure, unset variables,
#     or failed pipelines.
#
# Requirements:
#   - Azure CLI installed and ARM_* environment variables exported.
#   - Terraform and Packer installed.
#   - jq installed.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Required Commands
# ------------------------------------------------------------------------------
echo "NOTE: Validating required commands in PATH."

commands=("az" "terraform" "jq" "packer" "python3")

for cmd in "${commands[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${cmd}"
    exit 1
  fi
  echo "NOTE: Found required command: ${cmd}"
done

echo "NOTE: All required commands are available."

# ------------------------------------------------------------------------------
# ARM Environment Variables
# ------------------------------------------------------------------------------
echo "NOTE: Validating required environment variables."

required_vars=("ARM_CLIENT_ID" "ARM_CLIENT_SECRET" "ARM_SUBSCRIPTION_ID" "ARM_TENANT_ID")
all_set=true

for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    echo "ERROR: ${var} is not set or is empty."
    all_set=false
  else
    echo "NOTE: ${var} is set."
  fi
done

if [ "${all_set}" != "true" ]; then
  echo "ERROR: One or more required environment variables are missing."
  exit 1
fi

echo "NOTE: All required environment variables are set."

# ------------------------------------------------------------------------------
# Azure Login
# ------------------------------------------------------------------------------
echo "NOTE: Logging in to Azure using service principal..."

az login \
  --service-principal \
  --username "${ARM_CLIENT_ID}" \
  --password "${ARM_CLIENT_SECRET}" \
  --tenant "${ARM_TENANT_ID}" \
  > /dev/null 2>&1

az account set --subscription "${ARM_SUBSCRIPTION_ID}" > /dev/null 2>&1

ACCOUNT=$(az account show --query "name" --output tsv 2>/dev/null)
echo "NOTE: Azure login successful. Subscription: ${ACCOUNT}"

# ------------------------------------------------------------------------------
# Azure Provider Registrations
# ------------------------------------------------------------------------------
echo "NOTE: Checking Azure provider registrations..."

for namespace in Microsoft.CognitiveServices Microsoft.Communication; do
  STATE=$(az provider show \
    --namespace "${namespace}" \
    --query "registrationState" \
    --output tsv 2>/dev/null || true)

  if [ "${STATE}" != "Registered" ]; then
    echo "NOTE: Registering ${namespace}..."
    az provider register --namespace "${namespace}" --wait > /dev/null 2>&1 || true
    echo "NOTE: ${namespace} registered."
  else
    echo "NOTE: ${namespace} already registered."
  fi
done

# ------------------------------------------------------------------------------
# Azure OpenAI Model Check
# ------------------------------------------------------------------------------
# Not merely a lookup: a model can be in the catalog and still fail to deploy
# -- wrong version, SKU not offered in this region, retired, or no quota for
# this subscription. probe_azure.py --check tests all four, before anything
# is built. It reads the catalog, so it needs no deployment to exist yet.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/azure-config.sh"

mapfile -t MODEL_CHECKS < <(azure_model_checks)

if [ "${#MODEL_CHECKS[@]}" -eq 0 ]; then
  echo "ERROR: AZURE_MODELS in azure-config.sh is empty - nothing to deploy."
  exit 1
fi

# A primary that is not in the list yields an OpenClaw that starts fine and
# cannot run an agent. Terraform validates this too, but failing here means
# failing before anything is built.
if ! azure_model_for_alias "${AZURE_PRIMARY}" > /dev/null; then
  echo "ERROR: AZURE_PRIMARY is '${AZURE_PRIMARY}', which is not an alias in"
  echo "ERROR: AZURE_MODELS. Valid aliases:"
  azure_model_aliases | sed 's/^/ERROR:   /'
  exit 1
fi

echo "NOTE: Checking ${#MODEL_CHECKS[@]} model(s) in ${AZURE_LOCATION}" \
     "(${AZURE_SKU}), primary ${AZURE_PRIMARY}"

MODEL_FAILED=0
for check in "${MODEL_CHECKS[@]}"; do
  if result=$(python3 "${SCRIPT_DIR}/probe_azure.py" --check "${check}" \
       --location "${AZURE_LOCATION}" --sku "${AZURE_SKU}" 2>&1); then
    echo "NOTE: ${result}"
  else
    echo "ERROR: ${result}"
    MODEL_FAILED=1
  fi
done

if [ "${MODEL_FAILED}" -ne 0 ]; then
  echo "ERROR: One or more models in azure-config.sh cannot be deployed."
  echo "ERROR: Run ./probe_azure.py to see what this subscription can deploy"
  echo "ERROR: in ${AZURE_LOCATION}, then update AZURE_MODELS in azure-config.sh."
  exit 1
fi

echo "NOTE: All models in azure-config.sh are deployable."
echo "NOTE: Environment validation complete."
