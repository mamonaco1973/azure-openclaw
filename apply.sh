#!/bin/bash
# ================================================================================
# FILE: apply.sh
# ================================================================================
#
# Purpose:
#   Deploy the OpenClaw AI Agent Workstation on Azure.
#
# Deployment Flow:
#     1. Deploy core infrastructure (Terraform).
#     2. Build OpenClaw managed image (Packer).
#     3. Deploy OpenClaw VM host (Terraform).
#
# Design Principles:
#   - Fail-fast behavior using set -euo pipefail.
#   - Environment validation before execution.
#   - Post-build validation after provisioning completes.
#
# Requirements:
#   - Azure CLI installed and ARM_* environment variables set.
#   - Terraform and Packer installed and in PATH.
#   - check_env.sh and validate.sh present in working directory.
#
# Exit Codes:
#   0 = Success
#   1 = Validation failure or provisioning error
#
# ================================================================================


# ================================================================================
# SECTION: Configuration
# ================================================================================

# Fail on errors, unset variables, and pipe failures.
set -euo pipefail


# ================================================================================
# SECTION: Environment Validation
# ================================================================================

echo "NOTE: Running environment validation..."
./check_env.sh
if [ $? -ne 0 ]; then
  echo "ERROR: Environment check failed. Exiting."
  exit 1
fi


# ================================================================================
# PHASE 1: Core Infrastructure
# ================================================================================

echo "NOTE: Building core infrastructure..."

cd 01-core || {
  echo "ERROR: Directory 01-core not found"
  exit 1
}

terraform init
terraform apply -auto-approve

VAULT_NAME=$(terraform output -raw key_vault_name)
echo "NOTE: Key Vault: ${VAULT_NAME}"

cd ..


# ================================================================================
# PHASE 2: Build OpenClaw Managed Image (Packer)
# ================================================================================

echo "NOTE: Building OpenClaw managed image with Packer..."

cd 02-packer || {
  echo "ERROR: Directory 02-packer not found"
  exit 1
}

packer init ./openclaw.pkr.hcl
packer build \
  -var "client_id=${ARM_CLIENT_ID}" \
  -var "client_secret=${ARM_CLIENT_SECRET}" \
  -var "subscription_id=${ARM_SUBSCRIPTION_ID}" \
  -var "tenant_id=${ARM_TENANT_ID}" \
  -var "resource_group=openclaw-project-rg" \
  ./openclaw.pkr.hcl

cd ..

IMAGE_NAME=$(az image list \
  --resource-group openclaw-project-rg \
  --query "[?starts_with(name, 'openclaw_image')]|sort_by(@, &name)[-1].name" \
  --output tsv)

if [ -z "${IMAGE_NAME}" ]; then
  echo "ERROR: No openclaw_image found in openclaw-project-rg after Packer build."
  exit 1
fi

echo "NOTE: Using image: ${IMAGE_NAME}"


# ================================================================================
# PHASE 3: OpenClaw VM Host
# ================================================================================

echo "NOTE: Deploying OpenClaw VM host..."

cd 03-openclaw || {
  echo "ERROR: Directory 03-openclaw not found"
  exit 1
}

terraform init
terraform apply -auto-approve \
  -var="vault_name=${VAULT_NAME}" \
  -var="openclaw_image_name=${IMAGE_NAME}"

cd ..


# ================================================================================
# SECTION: Post-Deployment Validation
# ================================================================================

./validate.sh
