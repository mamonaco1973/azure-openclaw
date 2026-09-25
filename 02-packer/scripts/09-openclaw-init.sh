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
#   3. Configure a placeholder litellm model provider via CLI (custom_data.sh
#      replaces it at first boot with the list from azure-config.sh).
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
  - model_name: gpt-4.1
    litellm_params:
      model: azure/gpt-4.1
      api_base: https://placeholder.openai.azure.com/
      api_version: "2025-03-01-preview"
      api_key: sk-placeholder

  - model_name: gpt-4.1-nano
    litellm_params:
      model: azure/gpt-4.1-nano
      api_base: https://placeholder.openai.azure.com/
      api_version: "2025-03-01-preview"
      api_key: sk-placeholder



litellm_settings:
  drop_params: true

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
    '{\"baseUrl\":\"http://localhost:4000\",\"apiKey\":\"sk-openclaw\",\"api\":\"azure-openai-responses\",\"models\":[{\"id\":\"gpt-4.1\",\"name\":\"GPT-4.1\",\"api\":\"azure-openai-responses\"},{\"id\":\"gpt-4.1-nano\",\"name\":\"GPT-4.1 Nano\",\"api\":\"azure-openai-responses\"}]}' \
    --strict-json || true
  ${OPENCLAW_BIN} models set litellm/gpt-4.1 || true
  ${OPENCLAW_BIN} models set litellm/gpt-4.1-nano || true
  ${OPENCLAW_BIN} config set agents.defaults.model.primary litellm/gpt-4.1 || true
  ${OPENCLAW_BIN} approvals allowlist add --agent '*' '/**' || true
  ${OPENCLAW_BIN} approvals allowlist add --agent 'main' '/**' || true
"

echo "NOTE: [openclaw-init] stopping all openclaw and litellm processes"
pkill -u openclaw 2>/dev/null || true
sleep 3
pkill -9 -u openclaw 2>/dev/null || true
rm -f /tmp/openclaw-init.pid

echo "NOTE: [openclaw-init] writing workspace files"
WORKSPACE=/home/openclaw/.openclaw/workspace
mkdir -p "${WORKSPACE}"

cat > "${WORKSPACE}/HEARTBEAT.md" <<'HEARTBEAT'
# System Context

You are running on an Azure VM with the following capabilities:

- **exec tool**: Full shell access — use it to run commands directly. Never ask the user to run commands manually.
- **Azure CLI**: Pre-authenticated via VM managed identity. No az login needed.
- **Azure Cost Report**: Run `azure-cost-report` via exec — it prints month-to-date total, daily breakdown for last 7 days, and top services by spend.
- **Web**: Apache2 serves /var/www/html (world-writable) at http://localhost/ — write a file there and open it in the browser.

Read SYSTEM.md in this workspace for the full list of installed tools and capabilities.
HEARTBEAT

# Email is NOT described here, and neither is send-cost-report (which mails
# its output). Both depend on the openclaw-email-config secret, which the
# image cannot know about; custom_data.sh appends them to HEARTBEAT.md and
# SYSTEM.md at boot when it finds ACS credentials.
#
# The model list is not here either: it comes from azure-config.sh and the
# OpenClaw model picker shows it, so a copy here would only go stale.
echo "NOTE: [openclaw-init] writing SYSTEM.md to workspace"
cat > "${WORKSPACE}/SYSTEM.md" <<'SYSTEM'
# System Capabilities

This instance has the following tools and capabilities available via exec.

## Web publishing
Apache2 is installed and running. The document root is `/var/www/html`, and it
is world-writable, so you can publish a page with the exec tool and no sudo:

```bash
echo "<h1>hello</h1>" > /var/www/html/index.html
```

It is then served at http://localhost/ — open that with the browser tool to
show the user the result. Port 80 is not reachable from outside the instance,
so this is for showing things on the desktop, not for publishing to the web.

Anything self-contained works: a single HTML file, or HTML plus CSS and
JavaScript. Write the files, then open the page to demonstrate it.


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

chown -R openclaw:openclaw /home/openclaw/.openclaw

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
