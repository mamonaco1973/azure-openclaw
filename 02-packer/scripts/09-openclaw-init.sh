#!/bin/bash
set -euo pipefail

# ================================================================================
# OpenClaw Config Initialization
# ================================================================================
#
# Runs the openclaw gateway briefly as the openclaw user to stamp the config
# file with internal metadata. Without this step, openclaw detects a
# "missing-meta-before-write" condition on first launch and overwrites any
# pre-written config with defaults, discarding the litellm provider settings.
#
# Flow:
#   1. Start litellm with a placeholder Azure OpenAI config (placeholder creds).
#   2. Run openclaw gateway in background as openclaw user (stamps config).
#   3. Configure the litellm model provider via CLI (gpt-4o + gpt-4o-mini).
#   4. Stop both processes — config is persisted at /home/openclaw/.openclaw.
#
# Note: The placeholder config uses dummy Azure OpenAI creds. The real endpoint
# and API key are written by custom_data.sh at first boot from Key Vault.
#
# ================================================================================

echo "NOTE: [openclaw-init] writing placeholder litellm config"
mkdir -p /opt/openclaw
cat > /opt/openclaw/litellm-config.yaml <<'LITELLM'
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: azure/gpt-4o
      api_base: https://placeholder.openai.azure.com/
      api_version: "2024-10-21"
      api_key: sk-placeholder

  - model_name: gpt-4o-mini
    litellm_params:
      model: azure/gpt-4o-mini
      api_base: https://placeholder.openai.azure.com/
      api_version: "2024-10-21"
      api_key: sk-placeholder

general_settings:
  master_key: "sk-openclaw"
  drop_params: true
LITELLM
chown openclaw:openclaw /opt/openclaw/litellm-config.yaml

echo "NOTE: [openclaw-init] starting litellm placeholder"
sudo -u openclaw /opt/litellm-venv/bin/litellm \
  --config /opt/openclaw/litellm-config.yaml --port 4000 &
LITELLM_PID=$!
sleep 8

OPENCLAW_BIN=$(which openclaw)
echo "NOTE: [openclaw-init] openclaw binary: ${OPENCLAW_BIN}"

echo "NOTE: [openclaw-init] starting openclaw gateway to stamp config metadata"
sudo -u openclaw env HOME=/home/openclaw PATH="${PATH}" bash -c "
  ${OPENCLAW_BIN} gateway run \
    --allow-unconfigured --bind loopback --port 18789 &
  echo \$! > /tmp/openclaw-init.pid
"
sleep 12

echo "NOTE: [openclaw-init] configuring litellm model provider"
sudo -u openclaw env HOME=/home/openclaw PATH="${PATH}" bash -c "
  ${OPENCLAW_BIN} config set gateway.mode local || true
  ${OPENCLAW_BIN} config set gateway.auth.mode none || true
  ${OPENCLAW_BIN} config set models.providers.litellm \
    '{\"baseUrl\":\"http://localhost:4000\",\"apiKey\":\"sk-openclaw\",\"models\":[{\"id\":\"gpt-4o\",\"name\":\"GPT-4o (Azure OpenAI)\"},{\"id\":\"gpt-4o-mini\",\"name\":\"GPT-4o Mini (Azure OpenAI)\"}]}' \
    --strict-json || true
  ${OPENCLAW_BIN} models set litellm/gpt-4o-mini || true
  ${OPENCLAW_BIN} models set litellm/gpt-4o || true
  ${OPENCLAW_BIN} config set agents.defaults.model.primary litellm/gpt-4o || true
  ${OPENCLAW_BIN} approvals allowlist add --agent '*' '/**' || true
  ${OPENCLAW_BIN} approvals allowlist add --agent 'main' '/**' || true
"

echo "NOTE: [openclaw-init] stopping all openclaw and litellm processes"
pkill -u openclaw 2>/dev/null || true
sleep 3
pkill -9 -u openclaw 2>/dev/null || true
rm -f /tmp/openclaw-init.pid

echo "NOTE: [openclaw-init] writing CLAUDE.md to workspace"
WORKSPACE=/home/openclaw/.openclaw/workspace
mkdir -p "${WORKSPACE}"
cat > "${WORKSPACE}/CLAUDE.md" <<'CLAUDE'
You have full exec access via the exec tool. The Azure CLI is installed and
pre-authenticated via the VM managed identity — no credentials needed. Use
exec to run Azure CLI commands directly to complete any Azure task.

To send email use the acs-mail command via exec (if email is configured):
  echo "Message body" | acs-mail -s "Subject" -t recipient@example.com

Never tell the user to do something manually that you can do yourself via exec.
CLAUDE

echo "NOTE: [openclaw-init] writing SYSTEM.md to workspace"
cat > "${WORKSPACE}/SYSTEM.md" <<'SYSTEM'
# System Capabilities

This instance has the following tools and capabilities available via exec.

## AI Models (via LiteLLM on port 4000)
- **gpt-4o** — GPT-4o via Azure OpenAI (primary model)
- **gpt-4o-mini** — GPT-4o Mini via Azure OpenAI (fast/cost-efficient)

## Email
If Azure Communication Services is configured, use the `acs-mail` command:

```bash
# Plain text
echo "Body here" | acs-mail -s "Subject" -t recipient@example.com
```

Config is at /opt/openclaw/email-config.json if email is enabled.

## Document Processing
- **python-docx** — read/write Word documents
- **python-pptx** — read/write PowerPoint files
- **openpyxl** — read/write Excel files
- **pymupdf** — read/extract PDF content
- **reportlab** — generate PDFs
- **pandoc** — convert between document formats
- **OnlyOffice** — desktop app for editing DOCX/XLSX/PPTX files

## Data & Analysis
- **pandas**, **numpy** — data analysis
- **matplotlib** — charts and visualizations
- **sqlite3** — local database

## Web & HTTP
- **curl**, **wget** — HTTP requests
- **beautifulsoup4**, **lxml** — HTML parsing
- **httpx**, **requests** — Python HTTP

## Media
- **imagemagick** — image manipulation (convert, resize, crop)
- **ffmpeg** — video/audio processing
- **poppler-utils** — PDF utilities (pdftotext, pdfinfo)
- **ghostscript** — PDF manipulation

## Cloud
- **Azure CLI** — authenticated via managed identity (no credentials needed)
  - Key Vault, Azure OpenAI, Cost Management
- **AWS CLI** — available (configure credentials separately)
- **Terraform**, **Packer** — infrastructure tools
- **gcloud** — Google Cloud CLI

## File System
- Workspace: `~/.openclaw/workspace` (also accessible as `~/Openclaw/workspace`)
- Home: `/home/openclaw`

## Utilities
- **jq** — JSON processing
- **csvkit** — CSV tools
- **xmlstarlet** — XML processing
- **Rich** (Python) — formatted terminal output

SYSTEM

chown -R openclaw:openclaw "${WORKSPACE}"

echo "NOTE: [openclaw-init] appending SYSTEM.md reference to BOOTSTRAP.md"
BOOTSTRAP="${WORKSPACE}/BOOTSTRAP.md"
if [ -f "${BOOTSTRAP}" ]; then
  cat >> "${BOOTSTRAP}" <<'EOF'

---

## This System

Before you delete this file, read `SYSTEM.md` in this workspace — it lists
the tools, commands, and capabilities available on this machine (email, document
processing, Azure CLI, etc.). Keep that file around after onboarding.
EOF
fi

echo "NOTE: [openclaw-init] config directory contents:"
ls -la /home/openclaw/.openclaw/ 2>/dev/null || echo "(empty)"

echo "NOTE: [openclaw-init] done"
