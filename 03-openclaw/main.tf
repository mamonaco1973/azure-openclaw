# ================================================================================
# FILE: main.tf
# ================================================================================
#
# Purpose:
#   Configure the AzureRM provider and load shared resources created by
#   01-core via data sources: resource groups, VNet, subnet, Key Vault,
#   and the managed image built by 02-packer.
#
# ================================================================================

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
    }
  }
}

provider "random" {}


# ------------------------------------------------------------------------------
# Subscription and client identity
# ------------------------------------------------------------------------------
data "azurerm_subscription" "primary" {}
data "azurerm_client_config" "current" {}

# ------------------------------------------------------------------------------
# Resource groups created by 01-core
# ------------------------------------------------------------------------------
data "azurerm_resource_group" "network" {
  name = "openclaw-core-rg"
}

data "azurerm_resource_group" "project" {
  name = "openclaw-project-rg"
}

# ------------------------------------------------------------------------------
# Networking resources created by 01-core
# ------------------------------------------------------------------------------
data "azurerm_virtual_network" "openclaw_vnet" {
  name                = "openclaw-vnet"
  resource_group_name = data.azurerm_resource_group.network.name
}

data "azurerm_subnet" "vm_subnet" {
  name                 = "vm-subnet"
  resource_group_name  = data.azurerm_resource_group.network.name
  virtual_network_name = data.azurerm_virtual_network.openclaw_vnet.name
}

# ------------------------------------------------------------------------------
# Key Vault created by 01-core (name passed in via variable from apply.sh)
# ------------------------------------------------------------------------------
data "azurerm_key_vault" "openclaw_vault" {
  name                = var.vault_name
  resource_group_name = data.azurerm_resource_group.network.name
}

# ------------------------------------------------------------------------------
# Managed image built by 02-packer (name passed in via variable from apply.sh)
# ------------------------------------------------------------------------------
data "azurerm_image" "openclaw_image" {
  name                = var.openclaw_image_name
  resource_group_name = data.azurerm_resource_group.project.name
}
