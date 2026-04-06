#Azure #AIAgent #OpenClaw #LiteLLM #AzureOpenAI #Terraform #Packer #GPT4o

*Run an AI Agent on Azure in Minutes (OpenClaw + Azure OpenAI)*

Deploy a fully autonomous AI agent workstation on Azure using Terraform, Packer, OpenClaw, and Azure OpenAI. The agent runs on an Ubuntu VM with an LXQt desktop, backed by two models — GPT-4o and GPT-4o Mini — routed through a LiteLLM proxy.

In this project we give the agent a single natural language instruction and watch it query Azure Cost Management, generate a styled HTML report, send it by email through Azure Communication Services, and schedule itself as a nightly recurring task — no scripts written by hand, no credentials managed, no additional configuration.

WHAT YOU'LL LEARN
• Deploying an AI agent workstation on Azure with Terraform and Packer
• Routing Azure OpenAI models through LiteLLM for OpenAI-compatible access
• Giving an AI agent access to Azure APIs through a VM managed identity
• Configuring outbound email with Azure Communication Services
• Driving real automation with plain English instructions

INFRASTRUCTURE DEPLOYED
• VNet with VM subnet and NAT gateway (East US)
• Ubuntu 24.04 Azure VM (Standard_D4s_v3) with LXQt desktop and XRDP
• Packer-built managed image with OpenClaw, LiteLLM, Chrome, VS Code, and developer tooling
• LiteLLM proxy configured for GPT-4o and GPT-4o Mini via Azure OpenAI
• VM system-assigned managed identity with Key Vault and Cost Management access
• Azure Communication Services email with auto-verified managed domain
• Azure Key Vault secrets for desktop password, OpenAI config, and email config

GitHub
https://github.com/mamonaco1973/azure-openclaw

README
https://github.com/mamonaco1973/azure-openclaw/blob/main/README.md

TIMESTAMPS
00:00 Introduction
00:00 Architecture
00:00 Build the Code
00:00 Build Results
00:00 Demo
