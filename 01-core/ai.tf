# ================================================================================
# FILE: ai.tf
# ================================================================================
#
# Purpose:
#   Deploy Azure OpenAI Service with two model deployments:
#     - gpt-4o      (primary capable model — analogous to Claude Sonnet)
#     - gpt-4o-mini (fast/cost-efficient model — analogous to Claude Haiku)
#
#   The API key and endpoint are stored in Key Vault as openclaw-openai-config
#   so the VM can retrieve them at boot via managed identity.
#
# ================================================================================

# Random suffix for the OpenAI custom subdomain (must be globally unique).
resource "random_string" "openai_suffix" {
  length  = 8
  special = false
  upper   = false
}

# ------------------------------------------------------------------------------
# Azure OpenAI Cognitive Account
# ------------------------------------------------------------------------------
resource "azurerm_cognitive_account" "openai" {
  name                  = "openclaw-openai-${random_string.openai_suffix.result}"
  resource_group_name   = azurerm_resource_group.network.name
  location              = azurerm_resource_group.network.location
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = "openclaw-openai-${random_string.openai_suffix.result}"
}

# ------------------------------------------------------------------------------
# GPT-4o deployment — primary capable model
# ------------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = "gpt-4o"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4o"
    version = "2024-11-20"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 100
  }
}

# ------------------------------------------------------------------------------
# GPT-4o Mini deployment — fast / cost-efficient model
# ------------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "gpt4o_mini" {
  name                 = "gpt-4o-mini"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4o-mini"
    version = "2024-07-18"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 100
  }
}

# ------------------------------------------------------------------------------
# Store Azure OpenAI config in Key Vault
# The VM reads this at boot to write the LiteLLM config.
# ------------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "openai_config" {
  name         = "openclaw-openai-config"
  key_vault_id = azurerm_key_vault.openclaw_vault.id
  content_type = "application/json"

  value = jsonencode({
    endpoint          = azurerm_cognitive_account.openai.endpoint
    api_key           = azurerm_cognitive_account.openai.primary_access_key
    api_version       = "2025-03-01-preview"
    gpt4o_deployment      = azurerm_cognitive_deployment.gpt4o.name
    gpt4o_mini_deployment = azurerm_cognitive_deployment.gpt4o_mini.name
  })

  depends_on = [azurerm_role_assignment.kv_secrets_officer]
}
