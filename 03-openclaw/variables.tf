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


# ================================================================================
# SECTION: AI Models (Azure OpenAI)
# ================================================================================

# Populated from azure-config.sh via TF_VAR_models -- the same list 01-core
# deployed, so every alias here has a deployment of the same name. The
# defaults are a fallback for a bare `terraform apply` and are kept in step
# with that file.
variable "models" {
  description = "Azure OpenAI models LiteLLM serves to OpenClaw (from azure-config.sh)"

  type = list(object({
    alias    = string
    model    = string
    version  = string
    capacity = number
    display  = string
    format   = optional(string, "OpenAI")
  }))

  default = [
    {
      alias    = "gpt-4.1"
      model    = "gpt-4.1"
      version  = "2025-04-14"
      capacity = 100
      display  = "GPT-4.1"
    },
    {
      alias    = "gpt-4.1-nano"
      model    = "gpt-4.1-nano"
      version  = "2025-04-14"
      capacity = 100
      display  = "GPT-4.1 Nano"
    },
  ]

  validation {
    condition     = length(var.models) > 0
    error_message = "At least one model must be defined in azure-config.sh."
  }

  validation {
    condition     = length(distinct([for m in var.models : m.alias])) == length(var.models)
    error_message = "Model aliases must be unique - LiteLLM routes on the alias."
  }
}

variable "primary_alias" {
  description = "Alias from var.models that agents default to"
  type        = string
  default     = "gpt-4.1"

  # Cross-variable validation (Terraform >= 1.9). A primary that is not in the
  # list produces an OpenClaw that starts fine and cannot run an agent, which
  # is a far worse failure than a plan-time error.
  validation {
    condition     = contains([for m in var.models : m.alias], var.primary_alias)
    error_message = "primary_alias must be one of the aliases in var.models."
  }
}
