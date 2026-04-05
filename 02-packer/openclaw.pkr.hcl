# ================================================================================
# FILE: openclaw.pkr.hcl
# ================================================================================
#
# Purpose:
#   Build a self-contained Azure Managed Image from Ubuntu 24.04 with:
#     - LXQt desktop + XRDP
#     - Google Chrome
#     - Cloud CLIs: AWS CLI v2, Azure CLI, Google Cloud SDK
#     - Dev tools: Git, Terraform, Packer, VS Code
#     - Node.js 22, pnpm, OpenClaw
#     - LiteLLM proxy (Python venv)
#     - systemd services for LiteLLM and OpenClaw gateway
#
# Design:
#   - Base image: latest Canonical Ubuntu 24.04 LTS from Azure Marketplace.
#   - Fully self-contained — no dependency on a pre-built base image.
#   - Output image named "openclaw_image_<timestamp>" for use by 03-openclaw.
#   - Builder VM: Standard_D4s_v3 (4 vCPU / 16 GB RAM).
#
# ================================================================================


# ================================================================================
# SECTION: Packer Plugin Configuration
# ================================================================================

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}


# ================================================================================
# SECTION: Locals
# ================================================================================

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
}


# ================================================================================
# SECTION: Build-Time Variables
# ================================================================================

variable "client_id" {
  description = "Azure Client ID (ARM_CLIENT_ID)"
  type        = string
}

variable "client_secret" {
  description = "Azure Client Secret (ARM_CLIENT_SECRET)"
  type        = string
}

variable "subscription_id" {
  description = "Azure Subscription ID (ARM_SUBSCRIPTION_ID)"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID (ARM_TENANT_ID)"
  type        = string
}

variable "resource_group" {
  description = "Resource group to store the managed image (openclaw-project-rg)"
  type        = string
  default     = "openclaw-project-rg"
}

variable "location" {
  description = "Azure region to build in"
  type        = string
  default     = "East US"
}

variable "vm_size" {
  description = "Builder VM size"
  type        = string
  default     = "Standard_D4s_v3"
}


# ================================================================================
# SECTION: Azure-ARM Builder Source
# ================================================================================

source "azure-arm" "openclaw" {
  client_id       = var.client_id
  client_secret   = var.client_secret
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  image_publisher = "Canonical"
  image_offer     = "ubuntu-24_04-lts"
  image_sku       = "server"
  image_version   = "latest"

  location   = var.location
  vm_size    = var.vm_size
  os_type    = "Linux"
  ssh_username = "ubuntu"

  # Timestamped name allows multiple versions to coexist.
  # apply.sh resolves the latest via az image list.
  managed_image_name                 = "openclaw_image_${local.timestamp}"
  managed_image_resource_group_name  = var.resource_group
  managed_image_storage_account_type = "Premium_LRS"
  os_disk_size_gb                    = 128
}


# ================================================================================
# SECTION: Build Provisioners
# ================================================================================

build {
  sources = ["source.azure-arm.openclaw"]

  # Upload systemd service unit files and icon.
  provisioner "file" {
    source      = "./files/litellm.service"
    destination = "/tmp/litellm.service"
  }

  provisioner "file" {
    source      = "./files/openclaw-gateway.service"
    destination = "/tmp/openclaw-gateway.service"
  }

  provisioner "file" {
    source      = "./files/openclaw.png"
    destination = "/tmp/openclaw.png"
  }

  provisioner "file" {
    source      = "./files/xvfb.service"
    destination = "/tmp/xvfb.service"
  }

  # Remove snap, install base packages.
  provisioner "shell" {
    script          = "./scripts/01-packages.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install LXQt desktop environment.
  provisioner "shell" {
    script          = "./scripts/02-desktop.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install XRDP and configure LXQt session.
  provisioner "shell" {
    script          = "./scripts/03-xrdp.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install Google Chrome.
  provisioner "shell" {
    script          = "./scripts/04-chrome.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install cloud CLIs and dev tooling (git, AWS, HashiCorp, az, gcloud, VS Code).
  provisioner "shell" {
    script          = "./scripts/05-tools.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Create the openclaw Linux user with sudo access.
  provisioner "shell" {
    script          = "./scripts/06-user.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install Node.js 22, pnpm, and openclaw globally.
  provisioner "shell" {
    script          = "./scripts/07-node.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Create Python venv and install LiteLLM proxy.
  provisioner "shell" {
    script          = "./scripts/08-litellm.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install Python packages, system utilities, and ACS email SDK.
  provisioner "shell" {
    script          = "./scripts/11-python-tools.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install OnlyOffice Desktop Editors.
  provisioner "shell" {
    script          = "./scripts/12-onlyoffice.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install Azure helper scripts.
  provisioner "shell" {
    script          = "./scripts/13-azure-tools.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Run openclaw gateway briefly to stamp config metadata; configure Azure OpenAI models.
  provisioner "shell" {
    script          = "./scripts/09-openclaw-init.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  # Install and enable systemd service units.
  provisioner "shell" {
    script          = "./scripts/10-services.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }
}
