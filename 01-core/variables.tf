# ================================================================================
# FILE: variables.tf
# ================================================================================

variable "location" {
  description = "Azure region for all resources. East US has the broadest Azure OpenAI model availability."
  type        = string
  default     = "East US"
}
