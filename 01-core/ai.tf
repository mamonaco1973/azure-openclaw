# ================================================================================
# FILE: ai.tf
# ================================================================================
#
# Purpose:
#   Deploy Azure OpenAI Service with four model deployments:
#     - gpt-4.1       (primary agentic model)
#     - gpt-4.1-nano  (fast / cost-efficient)
#     - gpt-5         (most capable)
#     - gpt-5-mini    (capable / cost-efficient)
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
# GPT-4.1 deployment — primary agentic model
# ------------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "gpt41" {
  name                 = "gpt-4.1"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4.1"
    version = "2025-04-14"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 100
  }

  rai_policy_name = "Microsoft.DefaultV2"
}

# ------------------------------------------------------------------------------
# GPT-4.1 Nano deployment — fast / cost-efficient
# ------------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "gpt41_nano" {
  name                 = "gpt-4.1-nano"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4.1-nano"
    version = "2025-04-14"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 100
  }

  rai_policy_name = "Microsoft.DefaultV2"
}

# ------------------------------------------------------------------------------
# GPT-5 deployment — most capable model
# ------------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "gpt5" {
  name                 = "gpt-5"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-5"
    version = "2025-08-07"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 100
  }

  rai_policy_name = "Microsoft.DefaultV2"
}

# ------------------------------------------------------------------------------
# GPT-5 Mini deployment — capable / cost-efficient
# ------------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "gpt5_mini" {
  name                 = "gpt-5-mini"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-5-mini"
    version = "2025-08-07"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 100
  }

  rai_policy_name = "Microsoft.DefaultV2"
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
    endpoint              = azurerm_cognitive_account.openai.endpoint
    api_key               = azurerm_cognitive_account.openai.primary_access_key
    api_version           = "2025-03-01-preview"
    gpt41_deployment      = azurerm_cognitive_deployment.gpt41.name
    gpt41_nano_deployment = azurerm_cognitive_deployment.gpt41_nano.name
    gpt5_deployment       = azurerm_cognitive_deployment.gpt5.name
    gpt5_mini_deployment  = azurerm_cognitive_deployment.gpt5_mini.name
  })

  depends_on = [azurerm_role_assignment.kv_secrets_officer]
}
