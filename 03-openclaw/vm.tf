# ================================================================================
# FILE: vm.tf
# ================================================================================
#
# Purpose:
#   Azure Linux VM for the OpenClaw AI Agent Workstation.
#
# Design:
#   - System-assigned managed identity for credential-free access to Key Vault
#     and Azure services at runtime.
#   - Public IP for direct RDP access (port 3389) — same posture as the AWS
#     version which used a public EC2 instance.
#   - custom_data.sh runs at first boot to set the user password, write the
#     LiteLLM config, and start services.
#   - OS disk: 128 GB Premium SSD.
#
# ================================================================================

# Random suffix for globally-unique DNS label on the public IP.
resource "random_string" "vm_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ------------------------------------------------------------------------------
# Public IP
# ------------------------------------------------------------------------------
resource "azurerm_public_ip" "openclaw_pip" {
  name                = "openclaw-public-ip"
  location            = data.azurerm_resource_group.project.location
  resource_group_name = data.azurerm_resource_group.project.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "openclaw-${random_string.vm_suffix.result}"
}

# ------------------------------------------------------------------------------
# Network Interface
# ------------------------------------------------------------------------------
resource "azurerm_network_interface" "openclaw_nic" {
  name                = "openclaw-nic"
  location            = data.azurerm_resource_group.project.location
  resource_group_name = data.azurerm_resource_group.project.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.vm_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.openclaw_pip.id
  }
}

# ------------------------------------------------------------------------------
# Linux Virtual Machine
# ------------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "openclaw" {
  name                            = "openclaw-host"
  location                        = data.azurerm_resource_group.project.location
  resource_group_name             = data.azurerm_resource_group.project.name
  size           = var.vm_size
  admin_username                  = "ubuntu"
  admin_password                  = random_password.ubuntu.result
  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.openclaw_nic.id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_id = data.azurerm_image.openclaw_image.id

  boot_diagnostics {
    storage_account_uri = null
  }

  custom_data = base64encode(templatefile(
    "${path.module}/scripts/custom_data.sh",
    {
      vault_name = data.azurerm_key_vault.openclaw_vault.name

      # The raw list drives the LiteLLM model_list via a %{ for } loop in the
      # template. models_b64 is the same data pre-encoded for the OpenClaw
      # CLI: base64 so it drops into the shell script as one opaque token.
      # Raw JSON interpolated into bash breaks the moment a display name
      # contains an apostrophe; base64 has no quoting case at all.
      #
      # "api" matches what 09-openclaw-init.sh has always registered for
      # Azure -- this list replaces that one, so it keeps the same shape.
      models = var.models
      models_b64 = base64encode(jsonencode([
        for m in var.models : {
          id   = m.alias
          name = m.display
          api  = "azure-openai-responses"
        }
      ]))

      primary_alias = var.primary_alias
    }
  ))

  identity {
    type = "SystemAssigned"
  }

  tags = {
    Name = "openclaw-host"
  }
}
