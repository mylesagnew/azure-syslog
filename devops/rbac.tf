# ---------------------------------------------------------------------------
# Least-privilege role assignments for the pipeline identity.
# These mirror what ../terraform touches; nothing broader.
# ---------------------------------------------------------------------------
locals {
  principal_id = azurerm_user_assigned_identity.pipeline.principal_id

  # Built-in role definition IDs the pipeline may hand out (and nothing else).
  role_ids = {
    key_vault_secrets_user        = "4633458b-17de-408a-b874-0445c86b69e6"
    storage_blob_data_contributor = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
    vm_administrator_login        = "1c0163c0-47e6-4577-8991-ea5c82e286e4"
  }

  # ABAC condition: "Role Based Access Control Administrator" limited to the listed roles.
  constrained_rbac_condition = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {%ROLES%}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {%ROLES%}
     )
    )
  EOT

  workload_assignable = join(", ", [local.role_ids.storage_blob_data_contributor, local.role_ids.vm_administrator_login])
  kv_assignable       = local.role_ids.key_vault_secrets_user
}

# Create and manage the collector resources (RG, VMs, NSG, LB, DCR, storage ...).
resource "azurerm_role_assignment" "workload_contributor" {
  scope                = var.workload_scope_id
  role_definition_name = "Contributor"
  principal_id         = local.principal_id
  principal_type       = "ServicePrincipal"
}

# Grant only: Storage Blob Data Contributor (archive) + VM Administrator Login (Entra SSH).
resource "azurerm_role_assignment" "workload_rbac_admin" {
  scope                = var.workload_scope_id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = local.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = replace(local.constrained_rbac_condition, "%ROLES%", local.workload_assignable)
}

# Join NICs, the internal LB and the private endpoint to the LZ subnet(s).
resource "azurerm_role_assignment" "subnet" {
  for_each             = toset(var.subnet_ids)
  scope                = each.value
  role_definition_name = "Network Contributor"
  principal_id         = local.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "dns" {
  for_each             = toset(var.private_dns_zone_ids)
  scope                = each.value
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = local.principal_id
  principal_type       = "ServicePrincipal"
}

# DCR destination + diagnostic settings.
resource "azurerm_role_assignment" "workspace" {
  scope                = var.log_analytics_workspace_id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = local.principal_id
  principal_type       = "ServicePrincipal"
}

# Grant only "Key Vault Secrets User" (the collectors read the TLS cert).
resource "azurerm_role_assignment" "key_vault_rbac_admin" {
  count                = var.key_vault_id == null ? 0 : 1
  scope                = var.key_vault_id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = local.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = replace(local.constrained_rbac_condition, "%ROLES%", local.kv_assignable)
}

resource "azurerm_role_assignment" "state" {
  scope                = var.state_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.principal_id
  principal_type       = "ServicePrincipal"
}
