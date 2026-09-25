output "public_ip" {
  description = "Public IP for direct RDP access (port 3389)"
  value       = azurerm_public_ip.openclaw_pip.ip_address
}

output "public_fqdn" {
  description = "Public FQDN for direct RDP access (port 3389)"
  value       = azurerm_public_ip.openclaw_pip.fqdn
}

output "vault_name" {
  description = "Key Vault holding the openclaw credentials"
  value       = data.azurerm_key_vault.openclaw_vault.name
}

output "credentials_secret_id" {
  description = "Key Vault secret holding the openclaw username/password"
  value       = "openclaw-credentials"
}
