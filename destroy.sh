#!/bin/bash
# ================================================================================
# FILE: destroy.sh
# ================================================================================
#
# Purpose:
#   Orchestrate controlled teardown of the OpenClaw Azure infrastructure.
#
# Teardown Order:
#     1. Destroy OpenClaw VM host (03-openclaw).
#     2. Delete all openclaw_image managed images.
#     3. Destroy core infrastructure (01-core).
#
# Design Principles:
#   - Fail-fast behavior for safe teardown.
#
# Requirements:
#   - Azure CLI configured and authenticated (ARM_* vars set).
#   - Terraform installed and initialized per module.
#
# Exit Codes:
#   0 = Success
#   1 = Missing directories or Terraform/Azure CLI error
#
# ================================================================================

set -euo pipefail


# ================================================================================
# SECTION: Discover Shared Resources
# ================================================================================

VAULT_NAME=$(az keyvault list \
  --resource-group openclaw-network-rg \
  --query "[?starts_with(name, 'openclaw-vault')].name | [0]" \
  --output tsv 2>/dev/null || true)

IMAGE_NAME=$(az image list \
  --resource-group openclaw-project-rg \
  --query "[?starts_with(name, 'openclaw_image')]|sort_by(@, &name)[-1].name" \
  --output tsv 2>/dev/null || true)

echo "NOTE: Key Vault: ${VAULT_NAME:-<not found>}"
echo "NOTE: Latest image: ${IMAGE_NAME:-<not found>}"


# ================================================================================
# PHASE 1: Destroy OpenClaw VM Host
# ================================================================================

echo "NOTE: Destroying OpenClaw VM host..."

cd 03-openclaw || {
  echo "ERROR: Directory 03-openclaw not found"
  exit 1
}

terraform init

if [ -n "${VAULT_NAME}" ] && [ -n "${IMAGE_NAME}" ]; then
  terraform destroy -auto-approve \
    -var="vault_name=${VAULT_NAME}" \
    -var="openclaw_image_name=${IMAGE_NAME}"
else
  echo "NOTE: Missing vault or image name — attempting destroy with empty vars"
  terraform destroy -auto-approve \
    -var="vault_name=${VAULT_NAME:-placeholder}" \
    -var="openclaw_image_name=${IMAGE_NAME:-placeholder}"
fi

cd ..


# ================================================================================
# PHASE 2: Delete OpenClaw Managed Images
# ================================================================================

echo "NOTE: Deleting all openclaw_image managed images..."

az image list \
  --resource-group openclaw-project-rg \
  --query "[?starts_with(name, 'openclaw_image')].name" \
  --output tsv 2>/dev/null | while read -r IMAGE; do
    echo "NOTE: Deleting image: ${IMAGE}"
    az image delete \
      --name "${IMAGE}" \
      --resource-group openclaw-project-rg \
      || echo "WARNING: Failed to delete ${IMAGE}, skipping"
done


# ================================================================================
# PHASE 3: Destroy Core Infrastructure
# ================================================================================

echo "NOTE: Destroying core infrastructure..."

cd 01-core || {
  echo "ERROR: Directory 01-core not found"
  exit 1
}

terraform init
terraform destroy -auto-approve

cd ..


# ================================================================================
# SECTION: Completion
# ================================================================================

echo "NOTE: Infrastructure teardown complete."
