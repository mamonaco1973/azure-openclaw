# ================================================================================
# FILE: variables.tf
# ================================================================================

variable "vault_name" {
  description = "Name of the Key Vault created by 01-core (passed by apply.sh)"
  type        = string
}

variable "openclaw_image_name" {
  description = "Name of the managed image built by 02-packer (passed by apply.sh)"
  type        = string
}

variable "vm_size" {
  description = "Azure VM size for the OpenClaw host"
  type        = string
  default     = "Standard_D4s_v3"
}
