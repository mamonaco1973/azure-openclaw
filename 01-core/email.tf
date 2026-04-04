# ================================================================================
# FILE: email.tf
# ================================================================================
#
# Purpose:
#   Deploy Azure Communication Services for outbound email — the Azure-native
#   equivalent of AWS SES. Uses an Azure-managed domain so no DNS verification
#   is required.
#
#   Config is stored in Key Vault as openclaw-email-config. The VM reads it
#   at boot and installs the acs-mail Python wrapper. Email sending is optional:
#   if the secret is absent the boot script skips email configuration.
#
# ================================================================================

# ------------------------------------------------------------------------------
# Azure Communication Service (provides the connection string for API access)
# ------------------------------------------------------------------------------
resource "azurerm_communication_service" "openclaw" {
  name                = "openclaw-comms-${random_string.kv_suffix.result}"
  resource_group_name = azurerm_resource_group.network.name
  data_location       = "United States"
}

# ------------------------------------------------------------------------------
# Email Communication Service
# ------------------------------------------------------------------------------
resource "azurerm_email_communication_service" "openclaw" {
  name                = "openclaw-email-${random_string.kv_suffix.result}"
  resource_group_name = azurerm_resource_group.network.name
  data_location       = "United States"
}

# ------------------------------------------------------------------------------
# Azure Managed Domain — auto-verified, no custom DNS required.
# Provides a sender domain like <uuid>.azurecomm.net.
# ------------------------------------------------------------------------------
resource "azurerm_email_communication_service_domain" "azure_domain" {
  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.openclaw.id
  domain_management = "AzureManagedDomain"
}

# ------------------------------------------------------------------------------
# Store email config in Key Vault
# ------------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "email_config" {
  name         = "openclaw-email-config"
  key_vault_id = azurerm_key_vault.openclaw_vault.id
  content_type = "application/json"

  value = jsonencode({
    connection_string = azurerm_communication_service.openclaw.primary_connection_string
    from_address      = "DoNotReply@${azurerm_email_communication_service_domain.azure_domain.mail_from_sender_domain}"
  })

  depends_on = [azurerm_role_assignment.kv_secrets_officer]
}
