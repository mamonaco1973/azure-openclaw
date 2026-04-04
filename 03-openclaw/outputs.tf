output "public_ip" {
  description = "Public IP for direct RDP access (port 3389)"
  value       = azurerm_public_ip.openclaw_pip.ip_address
}

output "public_fqdn" {
  description = "Public FQDN for direct RDP access (port 3389)"
  value       = azurerm_public_ip.openclaw_pip.fqdn
}
