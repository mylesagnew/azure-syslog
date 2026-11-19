# ---- Azure ------------------------------------------------------------------
variable "subscription_id" {
  description = "Workload subscription (same as subscription_id in ../terraform). The pipeline identity lives here."
  type        = string
}

variable "subscription_name" {
  description = "Display name of the workload subscription (shown on the service connection)."
  type        = string
}

variable "location" {
  type    = string
  default = "australiaeast"
}

variable "environment" {
  description = "Environment code; matches environment in ../terraform (prd, nonprd ...)."
  type        = string
  default     = "prd"
}

variable "identity_resource_group_name" {
  description = "Resource group for the pipeline's user-assigned managed identity (created if create_identity_resource_group)."
  type        = string
  default     = "rg-syslog-devops-prd-aue-001"
}

variable "create_identity_resource_group" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---- Least-privilege scopes for the pipeline identity ------------------------
variable "workload_scope_id" {
  description = "Where the collectors are deployed: the workload subscription ID path (/subscriptions/<id>) when ../terraform creates the RG, or the existing RG ID."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet(s) the collectors, load balancer and private endpoint join (Network Contributor on each)."
  type        = list(string)
}

variable "private_dns_zone_ids" {
  description = "Private DNS zones Terraform writes records to (the syslog zone, and privatelink.blob... if blob_private_dns_zone_id is set)."
  type        = list(string)
  default     = []
}

variable "log_analytics_workspace_id" {
  description = "Central workspace (DCR destination and diagnostic settings)."
  type        = string
}

variable "key_vault_id" {
  description = "Key Vault holding the TLS certificate (null if not used). The identity may only grant 'Key Vault Secrets User' there."
  type        = string
  default     = null
}

variable "state_storage_account_id" {
  description = "Terraform state storage account (Storage Blob Data Contributor)."
  type        = string
}

# ---- Azure DevOps -------------------------------------------------------------
variable "azuredevops_org_url" {
  description = "https://dev.azure.com/<org>. null = AZDO_ORG_SERVICE_URL."
  type        = string
  default     = null
}

variable "azuredevops_project" {
  description = "Existing Azure DevOps project name."
  type        = string
}

# The pipeline YAML derives these names from its 'environment' parameter at compile
# time, so they are fixed: sc-azure-syslog-<env> and azure-syslog-<env>.

variable "approver_group_name" {
  description = "Azure DevOps group whose members approve applies (e.g. '[MyProject]\\\\Platform Approvers' or 'Platform Approvers')."
  type        = string
}

variable "allowed_branch" {
  description = "Only pipeline runs from this branch may use the service connection."
  type        = string
  default     = "refs/heads/main"
}

variable "admin_ssh_public_key" {
  description = "Public SSH key for the collectors' admin user (not secret). Stored in the variable group."
  type        = string
}
