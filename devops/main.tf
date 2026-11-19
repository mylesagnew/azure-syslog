# ---------------------------------------------------------------------------
# OIDC / workload identity federation for Azure DevOps - no secrets anywhere.
#
#   Azure DevOps service connection (WorkloadIdentityFederation)
#        │  issuer + subject
#        ▼
#   Federated credential on a user-assigned managed identity
#        │  role assignments (least privilege, constrained RBAC admin)
#        ▼
#   Landing Zone scopes used by ../terraform
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

data "azuredevops_project" "this" {
  name = var.azuredevops_project
}

resource "azurerm_resource_group" "identity" {
  count    = var.create_identity_resource_group ? 1 : 0
  name     = var.identity_resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "identity" {
  count = var.create_identity_resource_group ? 0 : 1
  name  = var.identity_resource_group_name
}

locals {
  service_connection_name   = "sc-azure-syslog-${var.environment}"
  pipeline_environment_name = "azure-syslog-${var.environment}"
  identity_rg               = var.create_identity_resource_group ? azurerm_resource_group.identity[0].name : data.azurerm_resource_group.identity[0].name
}

# A managed identity needs no Entra app registration rights and has no secret.
resource "azurerm_user_assigned_identity" "pipeline" {
  name                = "id-azure-syslog-pipeline-${var.environment}"
  location            = var.location
  resource_group_name = local.identity_rg
  tags                = var.tags
}

resource "azuredevops_serviceendpoint_azurerm" "this" {
  project_id                             = data.azuredevops_project.this.id
  service_endpoint_name                  = local.service_connection_name
  description                            = "azure-syslog ${var.environment} - workload identity federation (managed by Terraform)"
  service_endpoint_authentication_scheme = "WorkloadIdentityFederation"

  credentials {
    serviceprincipalid = azurerm_user_assigned_identity.pipeline.client_id
  }

  azurerm_spn_tenantid      = data.azurerm_client_config.current.tenant_id
  azurerm_subscription_id   = var.subscription_id
  azurerm_subscription_name = var.subscription_name
}

resource "azurerm_federated_identity_credential" "ado" {
  name                = "ado-${local.service_connection_name}"
  resource_group_name = local.identity_rg
  parent_id           = azurerm_user_assigned_identity.pipeline.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azuredevops_serviceendpoint_azurerm.this.workload_identity_federation_issuer
  subject             = azuredevops_serviceendpoint_azurerm.this.workload_identity_federation_subject
}

# Only the protected branch can use the connection.
resource "azuredevops_check_branch_control" "service_connection" {
  project_id           = data.azuredevops_project.this.id
  display_name         = "Only ${var.allowed_branch}"
  target_resource_id   = azuredevops_serviceendpoint_azurerm.this.id
  target_resource_type = "endpoint"
  allowed_branches     = var.allowed_branch

  verify_branch_protection         = false
  ignore_unknown_protection_status = false
}

# ---------------------------------------------------------------------------
# Approval gate: every apply/destroy waits for a human in this group.
# ---------------------------------------------------------------------------
resource "azuredevops_environment" "this" {
  project_id  = data.azuredevops_project.this.id
  name        = local.pipeline_environment_name
  description = "azure-syslog ${var.environment} - applies require approval"
}

data "azuredevops_group" "approvers" {
  project_id = data.azuredevops_project.this.id
  name       = var.approver_group_name
}

resource "azuredevops_check_approval" "this" {
  project_id           = data.azuredevops_project.this.id
  target_resource_id   = azuredevops_environment.this.id
  target_resource_type = "environment"

  approvers                  = [data.azuredevops_group.approvers.origin_id]
  minimum_required_approvers = 1
  requester_can_approve      = false
  instructions               = "Review the Terraform plan artifact (plan.txt) before approving."
  timeout                    = 4320 # minutes (3 days)
}

# ---------------------------------------------------------------------------
# Non-secret pipeline settings. tfvars + backend.hcl go in Secure Files.
# ---------------------------------------------------------------------------
resource "azuredevops_variable_group" "this" {
  project_id   = data.azuredevops_project.this.id
  name         = "azure-syslog-${var.environment}"
  description  = "azure-syslog pipeline settings (managed by Terraform). No secrets."
  allow_access = false

  variable {
    name  = "SERVICE_CONNECTION"
    value = azuredevops_serviceendpoint_azurerm.this.service_endpoint_name
  }
  variable {
    name  = "PIPELINE_ENVIRONMENT"
    value = azuredevops_environment.this.name
  }
  variable {
    name  = "ENVIRONMENT_CODE"
    value = var.environment
  }
  variable {
    name  = "ARM_CLIENT_ID"
    value = azurerm_user_assigned_identity.pipeline.client_id
  }
  variable {
    name  = "ARM_TENANT_ID"
    value = data.azurerm_client_config.current.tenant_id
  }
  variable {
    name  = "ARM_SUBSCRIPTION_ID"
    value = var.subscription_id
  }
  variable {
    name  = "ADMIN_SSH_PUBLIC_KEY"
    value = var.admin_ssh_public_key
  }
}
