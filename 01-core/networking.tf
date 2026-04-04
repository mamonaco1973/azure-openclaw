# ================================================================================
# FILE: networking.tf
# ================================================================================
#
# Purpose:
#   Baseline networking for the OpenClaw environment:
#     - VNet (10.0.0.0/23)
#     - vm-subnet (10.0.0.0/25) with NSG allowing RDP inbound
#     - NAT Gateway for outbound internet access (API calls, package updates)
#
# ================================================================================

# ------------------------------------------------------------------------------
# Virtual Network
# ------------------------------------------------------------------------------
resource "azurerm_virtual_network" "openclaw_vnet" {
  name                = "openclaw-vnet"
  address_space       = ["10.0.0.0/23"]
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
}

# ------------------------------------------------------------------------------
# VM Subnet (10.0.0.0/25)
# Default outbound disabled — egress goes through NAT gateway.
# ------------------------------------------------------------------------------
resource "azurerm_subnet" "vm_subnet" {
  name                            = "vm-subnet"
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.openclaw_vnet.name
  address_prefixes                = ["10.0.0.0/25"]
  default_outbound_access_enabled = false
}

# ------------------------------------------------------------------------------
# Network Security Group
# RDP inbound (3389) — same posture as the AWS version.
# All outbound allowed for Bedrock-equivalent API calls and package updates.
# ------------------------------------------------------------------------------
resource "azurerm_network_security_group" "openclaw_nsg" {
  name                = "openclaw-nsg"
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name

  security_rule {
    name                       = "Allow-RDP"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm_nsg_assoc" {
  subnet_id                 = azurerm_subnet.vm_subnet.id
  network_security_group_id = azurerm_network_security_group.openclaw_nsg.id
}

# ------------------------------------------------------------------------------
# NAT Gateway — stable outbound IP for the VM subnet
# ------------------------------------------------------------------------------
resource "azurerm_public_ip" "nat_gateway_pip" {
  name                = "openclaw-nat-pip"
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "openclaw_nat" {
  name                    = "openclaw-nat-gateway"
  location                = azurerm_resource_group.network.location
  resource_group_name     = azurerm_resource_group.network.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
}

resource "azurerm_nat_gateway_public_ip_association" "nat_pip_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.openclaw_nat.id
  public_ip_address_id = azurerm_public_ip.nat_gateway_pip.id
}

resource "azurerm_subnet_nat_gateway_association" "vm_nat_assoc" {
  subnet_id      = azurerm_subnet.vm_subnet.id
  nat_gateway_id = azurerm_nat_gateway.openclaw_nat.id
}
