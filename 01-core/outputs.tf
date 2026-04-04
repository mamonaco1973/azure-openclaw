# ================================================================================
# FILE: outputs.tf
# ================================================================================

output "key_vault_name" {
  description = "Key Vault name — passed to 03-openclaw and used in destroy.sh"
  value       = azurerm_key_vault.openclaw_vault.name
}

output "openai_endpoint" {
  description = "Azure OpenAI endpoint URL"
  value       = azurerm_cognitive_account.openai.endpoint
}
