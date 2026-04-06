# Video Script — AI Agent Workstation on Azure with OpenClaw

---

## Introduction

[ Screen recording of OpenClaw running the cost report — agent executing commands, email arriving in inbox ]

"Do you want an AI agent that can automate cloud tasks directly inside your Azure environment?"

[ Architecture diagram — walk through it left to right: user, Azure VM, Azure OpenAI ]

"In this project we deploy an AI agent workstation on Azure using Terraform, Packer, OpenClaw, and Azure OpenAI."

[ OpenClaw UI showing the agent mid-task with terminal output visible ]

"The agent runs on an Azure VM with access to the filesystem, terminal, browser, and Azure APIs — all through the VM managed identity. No credentials to manage, no keys to rotate."

[ Terminal running apply.sh — flying through build steps, ends with VM IP and connection details ]

"Follow along and in minutes you'll have a fully functional AI agent running in your Azure environment."

---

## Architecture

[ Full diagram ]

"Let's walk through the architecture before we build."

[ Highlight Azure VM ]

"At the center is an Ubuntu VM with a desktop environment — the agent's workstation. You connect over RDP and get a normal desktop with Chrome, VS Code, and a terminal."

[ Highlight OpenClaw gateway ]

"OpenClaw runs on that VM and gives the agent its capabilities — shell execution, filesystem access, browser control, and email."

[ Highlight LiteLLM + Azure OpenAI ]

"Reasoning goes through LiteLLM, which proxies requests to Azure OpenAI — GPT-4o for complex tasks, GPT-4o Mini for fast lightweight work."

[ Highlight Azure Communication Services ]

"Outbound email routes through Azure Communication Services with an auto-verified managed domain — no DNS configuration required."

[ Highlight Key Vault ]

"All secrets — the VM password, OpenAI config, and email connection string — live in Azure Key Vault. The VM pulls them at boot using its managed identity."

[ Full diagram ]

"A workstation on Azure, an AI agent on top of it, wired to Azure OpenAI and Azure services. Let's build it."

---

## Build the Code

[ Terminal — running ./apply.sh ]

"A single script — apply.sh — handles the entire deployment."

[ Terminal — 01-core Terraform applying ]

"Phase one deploys the core infrastructure: VNet, NAT gateway, Key Vault, Azure OpenAI with both model deployments, and Azure Communication Services for email."

[ Terminal — Packer build running ]

"Phase two runs Packer to build the managed image from a clean Ubuntu 24.04 base. It installs the LXQt desktop, XRDP, Chrome, VS Code, OpenClaw, LiteLLM, and all supporting tools."

[ Terminal — 03-openclaw Terraform applying ]

"Phase three deploys the VM from that image, attaches the managed identity, assigns RBAC roles, and runs the first-boot script to wire everything together."

[ Terminal — validate.sh output, IP address printed ]

"When it finishes, the VM's public IP is printed. That's all you need to connect."

---

## Build Results

[ Terminal — build complete, IP and connection details printed ]

"The build has completed. Let's go into the portal and see what was deployed."

[ Azure Portal — resource group openclaw-core-rg, resources listed ]

"The core resource group holds the VNet, Key Vault, Azure OpenAI account, and Azure Communication Services."

[ Azure Portal — Azure OpenAI deployments: gpt-4o and gpt-4o-mini ]

"Two model deployments are ready — GPT-4o as the primary model and GPT-4o Mini for fast responses."

[ Azure Portal — Key Vault secrets: openclaw-credentials, openclaw-openai-config, openclaw-email-config ]

"Key Vault holds three secrets. The VM reads all of them at first boot using its managed identity — no credentials ever touch the code."

[ Azure Portal — VM openclaw-host, managed identity tab ]

"The VM has a system-assigned managed identity. It's been granted Key Vault Secrets User and Cost Management Reader — just enough access to do its job."

[ RDP session connecting — LXQt desktop loads ]

"Connect over RDP and the desktop is ready. Chrome, VS Code, a terminal — everything the agent needs to do real work."

[ Chrome opening to localhost:18789 — OpenClaw UI ]

"OpenClaw is already running. Open Chrome and the agent interface is waiting."

---

## Demo

[ OpenClaw UI — empty prompt box ]

"Let's give the agent its first task. One sentence, plain English."

[ Typing the prompt ]

"Generate an Azure cost report with the month-to-date total, a daily breakdown for the last 7 days, and the top services by spend this month. Send it as a formatted HTML email to XXXXXXXX using acs-mail."

[ Agent working — Azure CLI calls visible, script being written and executed ]

"The agent figures out how to do this on its own. It calls Azure Cost Management, builds an HTML report, and sends it through acs-mail — no additional instructions."

[ Inbox — styled HTML cost report email arrives ]

"There's the report. Month-to-date total, daily breakdown, top services — formatted HTML, delivered through Azure Communication Services."

[ Back to OpenClaw — typing follow-up prompt ]

"Now let's make it recurring. Same agent, one more line."

[ Typing the prompt ]

"Schedule that as a nightly report."

[ Agent writing script to disk, adding crontab entry — cron confirmation visible ]

"The agent saves the script and registers a cron job. It runs every night automatically, no further input needed."

---
