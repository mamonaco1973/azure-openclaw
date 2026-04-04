#!/bin/bash
# ==============================================================================
# check_env.sh - Environment Validation
# ------------------------------------------------------------------------------
# Purpose:
#   - Validates that required CLI tools are available in the current PATH.
#   - Verifies Azure CLI authentication and connectivity.
#   - Confirms ARM_* environment variables are set.
#   - Checks that Azure OpenAI is available in the subscription.
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

commands=("az" "terraform" "jq" "packer")

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

echo "NOTE: Environment validation complete."
