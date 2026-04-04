# ================================================================================
# FILE: rbac.tf
# ================================================================================
#
# Purpose:
#   Grant the OpenClaw VM managed identity the permissions it needs at runtime:
#
#   - Key Vault Secrets User — read secrets (password, OpenAI config, email config)
#   - Cost Management Reader — query Azure spending via CLI
#
# ================================================================================

# Grant VM identity permission to read Key Vault secrets.
resource "azurerm_role_assignment" "vm_kv_secrets_user" {
  scope                = data.azurerm_key_vault.openclaw_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.openclaw.identity[0].principal_id
}

# Grant VM identity permission to read Azure cost data.
resource "azurerm_role_assignment" "vm_cost_reader" {
  scope                = data.azurerm_subscription.primary.id
  role_definition_name = "Cost Management Reader"
  principal_id         = azurerm_linux_virtual_machine.openclaw.identity[0].principal_id
}
