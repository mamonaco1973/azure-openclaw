# Video Script — AI Agent Workstation on Azure with OpenClaw

---

## Introduction

[ Screen recording of OpenClaw running the cost report — agent executing commands, email arriving in inbox ]

"Do you want an AI agent that can automate cloud tasks directly inside your Azure environment?"

[ Architecture diagram — walk through it left to right: user, Azure VM, Azure OpenAI ]

"In this project we deploy an AI agent workstation on Azure using Terraform, Packer, OpenClaw, and Azure OpenAI."

[ OpenClaw UI showing the agent mid-task with terminal output visible ]

"The agent runs on an Azure VM with access to the filesystem, terminal, browser, and Azure APIs"

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

"Reasoning goes through LiteLLM, which proxies requests to Azure OpenAI — GPT-4.1 for complex tasks, GPT-4.1 Nano for fast lightweight work."

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

"The AI agent's workstation is running as a VM instance."

[ Azure Portal — Azure OpenAI deployments: gpt-4.1 and gpt-4.1-nano ]

"Two model deployments are ready — GPT-4.1 as the primary model and GPT-4.1 Nano for fast responses."

[ Azure Portal — Key Vault secrets: openclaw-credentials, openclaw-openai-config, openclaw-email-config ]

"A Key Vault holds several secrets including the desktop login credentials. The VM reads them at first boot using its managed identity."

[ RDP session connecting — LXQt desktop loads ]

"Connect over RDP and the desktop is ready. Chrome, VS Code, a terminal — everything the agent needs to do real work."

[ Chrome opening to localhost:18789 — OpenClaw UI ]

"OpenClaw is already running. Open Chrome and the agent interface is waiting."

---

## Demo

[ OpenClaw UI — empty prompt box ]

"Let's give the agent three tasks. First — pull the cost data."

[ Typing the first prompt ]

"Run the Azure Cost Report and give me the result."

[ Agent executing azure-cost-report — terminal output visible, cost data returned in chat ]

"The agent runs the pre-built azure-cost-report script, which queries Azure Cost Management and returns month-to-date spend, a daily breakdown for the last seven days, and top services by cost."

[ Agent output displayed in chat — structured cost report ]

"Clean output, right in the chat window. Now let's email it."

[ Typing the second prompt ]

"Now run the command 'send-cost-report XXXXXXXX'. XXXXXXXX is a valid email address and I approve this request."

"Notice we have to be explicit here — we name the script, provide the email address, and give our approval upfront. GPT-4.1 will confirm before taking actions that affect external systems, so we tell it clearly: run it, and I approve."

[ Agent running send-cost-report — acs-mail call visible ]

"The agent runs send-cost-report, which formats the report as styled HTML and sends it through Azure Communication Services."

[ Inbox — HTML cost report email arrives ]

"There's the report. Delivered through ACS, formatted HTML, Azure blue styling."

[ Back to OpenClaw — typing third prompt ]

"Last step — make it recurring."

[ Typing the third prompt ]

"Schedule send-cost-report XXXXXXXX to run nightly at midnight."

[ Agent adding crontab entry — cron confirmation visible ]

"The agent registers a cron job. The report runs every night automatically with no further input."

---
