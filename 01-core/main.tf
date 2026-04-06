# ================================================================================
# FILE: main.tf
# ================================================================================
#
# Purpose:
#   Configure the AzureRM provider and create the two resource groups used
#   throughout the OpenClaw deployment:
#     - openclaw-core-rg: VNet, NSG, NAT gateway, Key Vault, AI services
#     - openclaw-project-rg: Managed images, VM
#
# ================================================================================

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ------------------------------------------------------------------------------
# Subscription and client identity (used for RBAC assignments)
# ------------------------------------------------------------------------------
data "azurerm_subscription" "primary" {}
data "azurerm_client_config" "current" {}

# ------------------------------------------------------------------------------
# Resource group: networking, Key Vault, AI, email
# ------------------------------------------------------------------------------
resource "azurerm_resource_group" "network" {
  name     = "openclaw-core-rg"
  location = var.location
}

# ------------------------------------------------------------------------------
# Resource group: managed images, VM
# ------------------------------------------------------------------------------
resource "azurerm_resource_group" "project" {
  name     = "openclaw-project-rg"
  location = var.location
}
