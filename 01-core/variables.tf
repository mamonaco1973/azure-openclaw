# ================================================================================
# FILE: variables.tf
# ================================================================================

# Populated from azure-config.sh (AZURE_LOCATION) via TF_VAR_location. The
# default matches that file; "eastus" and "East US" are the same region to the
# provider, so switching forms does not replace anything.
variable "location" {
  description = "Azure region for all resources. East US has the broadest Azure OpenAI model availability."
  type        = string
  default     = "eastus"
}


# ================================================================================
# SECTION: AI Models (Azure OpenAI)
# ================================================================================

# Populated from azure-config.sh via TF_VAR_models. The defaults here are a
# fallback for a bare `terraform apply` and are kept in step with that file --
# apply.sh always exports over them.
variable "models" {
  description = "Azure OpenAI models to deploy (from azure-config.sh)"

  type = list(object({
    # Deployment name, LiteLLM model_name, and OpenClaw model id.
    alias = string

    # Azure OpenAI model name and version, e.g. gpt-4.1 / 2025-04-14.
    model   = string
    version = string

    # Thousands of tokens per minute, drawn from the subscription's quota.
    capacity = number

    # Shown in the OpenClaw model picker.
    display = string

    # Catalog provider format: OpenAI, DeepSeek, Meta, Mistral AI, ...
    format = optional(string, "OpenAI")
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
    error_message = "Model aliases must be unique - each one is a deployment name."
  }
}

variable "deployment_sku" {
  description = "SKU for every model deployment (AZURE_SKU in azure-config.sh)"
  type        = string
  default     = "GlobalStandard"
}
