# ================================================================================
# FILE: accounts.tf
# ================================================================================
#
# Purpose:
#   Generate a memorable password for the local openclaw Linux user and store
#   it in Azure Key Vault. The VM reads this secret at first boot via managed
#   identity to set the account password.
#
# Design:
#   - Password format: <word>-<6-digit-number>
#   - No credentials exposed via Terraform outputs.
#
# ================================================================================


# ================================================================================
# SECTION: ubuntu Admin Password Generation
# ================================================================================

resource "random_password" "ubuntu" {
  length           = 20
  special          = true
  override_special = "!@#$%^&*"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# ================================================================================
# SECTION: openclaw User Password Generation
# ================================================================================

locals {
  memorable_words = [
    "bright", "simple", "orange", "window", "little",
    "people", "friend", "yellow", "animal", "family",
    "circle", "moment", "summer", "button", "planet",
    "rocket", "silver", "forest", "stream", "butter",
    "castle", "wonder", "gentle", "driver", "coffee"
  ]
}

resource "random_shuffle" "word" {
  input        = local.memorable_words
  result_count = 1
}

resource "random_integer" "num" {
  min = 100000
  max = 999999
}

locals {
  openclaw_password = format("%s-%d",
    random_shuffle.word.result[0],
    random_integer.num.result
  )
}


# ================================================================================
# SECTION: Key Vault Secret
# ================================================================================

resource "azurerm_key_vault_secret" "ubuntu_credentials" {
  name         = "ubuntu-credentials"
  key_vault_id = data.azurerm_key_vault.openclaw_vault.id
  content_type = "application/json"

  value = jsonencode({
    username = "ubuntu"
    password = random_password.ubuntu.result
  })
}

resource "azurerm_key_vault_secret" "openclaw_credentials" {
  name         = "openclaw-credentials"
  key_vault_id = data.azurerm_key_vault.openclaw_vault.id
  content_type = "application/json"

  value = jsonencode({
    username = "openclaw"
    password = local.openclaw_password
  })
}
