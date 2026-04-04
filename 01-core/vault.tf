# ================================================================================
# FILE: vault.tf
# ================================================================================
#
# Purpose:
#   Create an Azure Key Vault for storing all OpenClaw secrets:
#     - openclaw-credentials  (VM user password)
#     - openclaw-openai-config (Azure OpenAI endpoint + API key)
#     - openclaw-email-config  (ACS email connection string)
#
#   RBAC authorization is used (no legacy access policies).
#   The deploying identity receives Key Vault Secrets Officer so it can
#   populate secrets during apply. The VM managed identity receives
#   Key Vault Secrets User (granted in 03-openclaw/rbac.tf).
#
# ================================================================================

# Random suffix — Key Vault names must be globally unique (3–24 chars).
resource "random_string" "kv_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_key_vault" "openclaw_vault" {
  name                       = "openclaw-vault-${random_string.kv_suffix.result}"
  resource_group_name        = azurerm_resource_group.network.name
  location                   = azurerm_resource_group.network.location
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  purge_protection_enabled   = false
  rbac_authorization_enabled = true
}

# Grant the Terraform deploying identity permission to write secrets.
resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.openclaw_vault.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
