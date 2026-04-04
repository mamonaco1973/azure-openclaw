#!/bin/bash
# ================================================================================
# validate.sh
#
# Purpose:
#   Post-deploy validation for the OpenClaw AI Agent Workstation on Azure.
#   Reads Terraform outputs and prints a quick-start summary of all key
#   connection details needed to RDP into the VM.
#
# Requirements:
#   - terraform CLI installed and authenticated
#   - Azure credentials configured (ARM_* vars set)
#   - Terraform state must exist (run apply.sh first)
# ================================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/03-openclaw"

# ================================================================================
# Read Terraform outputs
# ================================================================================

cd "${TF_DIR}"

PUBLIC_IP="$(terraform output -raw public_ip    2>/dev/null || echo '<not found>')"
PUBLIC_FQDN="$(terraform output -raw public_fqdn 2>/dev/null || echo '<not found>')"

# ================================================================================
# Quick Start Output
# ================================================================================

echo ""
echo "============================================================================"
echo "OpenClaw AI Agent Workstation - Quick Start (Azure)"
echo "============================================================================"
echo ""

printf "%-28s %s\n" "NOTE: Public IP:"            "${PUBLIC_IP}"
printf "%-28s %s\n" "NOTE: Public FQDN:"          "${PUBLIC_FQDN}"
echo ""
printf "%-28s %s\n" "NOTE: RDP Host:"             "${PUBLIC_IP}:3389"
printf "%-28s %s\n" "NOTE: Username:"             "openclaw"
printf "%-28s %s\n" "NOTE: Password:"             "See Key Vault secret: openclaw-credentials"
echo ""
printf "%-28s %s\n" "NOTE: OpenClaw UI:"          "http://localhost:18789  (inside RDP session)"
printf "%-28s %s\n" "NOTE: LiteLLM port:"         "4000  (loopback only)"
echo ""
