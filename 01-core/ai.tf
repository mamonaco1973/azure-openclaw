# ================================================================================
# FILE: ai.tf
# ================================================================================
#
# Purpose:
#   Deploy Azure OpenAI Service with one model deployment per entry in
#   var.models, which apply.sh populates from azure-config.sh. Each deployment
#   is named after its alias -- the name LiteLLM routes on and OpenClaw stores.
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
# Model deployments -- one per entry in azure-config.sh
# ------------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "model" {
  for_each = { for m in var.models : m.alias => m }

  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = each.value.format
    name    = each.value.model
    version = each.value.version
  }

  sku {
    name     = var.deployment_sku
    capacity = each.value.capacity
  }

  rai_policy_name = "Microsoft.DefaultV2"
}

# These two deployments were separate resources before the model list moved
# into azure-config.sh. The moved blocks carry their state to the new
# addresses so an upgrade updates them in place rather than deleting and
# recreating them (which would briefly take the models away from LiteLLM).
moved {
  from = azurerm_cognitive_deployment.gpt41
  to   = azurerm_cognitive_deployment.model["gpt-4.1"]
}

moved {
  from = azurerm_cognitive_deployment.gpt41_nano
  to   = azurerm_cognitive_deployment.model["gpt-4.1-nano"]
}


# ------------------------------------------------------------------------------
# Store Azure OpenAI config in Key Vault
# The VM reads this at boot to write the LiteLLM config.
# ------------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "openai_config" {
  name         = "openclaw-openai-config"
  key_vault_id = azurerm_key_vault.openclaw_vault.id
  content_type = "application/json"

  # Deployment names are not stored here any more: they are the aliases in
  # var.models, which 03-openclaw receives directly from azure-config.sh.
  #
  # foundry_endpoint serves every format through one OpenAI-compatible route
  # (/openai/v1); custom_data.sh uses it for the non-OpenAI models.
  value = jsonencode({
    endpoint         = azurerm_cognitive_account.openai.endpoint
    foundry_endpoint = "https://${azurerm_cognitive_account.openai.custom_subdomain_name}.services.ai.azure.com/"
    api_key          = azurerm_cognitive_account.openai.primary_access_key
    api_version      = "2025-03-01-preview"
  })

  # Written after the deployments exist, so a VM that reads this secret never
  # finds an endpoint whose models are still provisioning.
  depends_on = [
    azurerm_role_assignment.kv_secrets_officer,
    azurerm_cognitive_deployment.model,
  ]
}
