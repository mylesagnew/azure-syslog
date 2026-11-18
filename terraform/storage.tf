# ---------------------------------------------------------------------------
# Log archive: the bulk of retained syslog lives in Blob Storage.
#
#   VM Premium SSD (/var/log/remote)  -> last local_log_retention_days (7)
#   Blob Storage, Cool tier           -> every rotated file, deleted by the
#                                        lifecycle policy after
#                                        blob_retention_days (30)
#
# The collectors upload with their managed identity over a private endpoint.
# No account keys exist (shared key auth is disabled) and the account has no
# public endpoint. Everything below is management-plane only, so it deploys
# from Cloud Shell even though the data plane is private.
# ---------------------------------------------------------------------------

resource "random_string" "archive_suffix" {
  count   = var.enable_blob_archive && var.archive_storage_account_name == null ? 1 : 0
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  archive_account_name = var.enable_blob_archive ? coalesce(
    var.archive_storage_account_name,
    substr(replace(lower("st${var.workload}${var.environment}${var.location_short}${try(random_string.archive_suffix[0].result, "")}"), "/[^a-z0-9]/", ""), 0, 24)
  ) : ""
}

resource "azurerm_storage_account" "archive" {
  count = var.enable_blob_archive ? 1 : 0

  name                     = local.archive_account_name
  resource_group_name      = local.resource_group_name
  location                 = var.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.archive_replication_type
  access_tier              = "Cool" # 30-day Cool minimum == 30-day retention: no early-deletion charge

  # MCSB: identity-only access, private only, TLS 1.2+, no anonymous blobs.
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  public_network_access_enabled     = false
  allow_nested_items_to_be_public   = false
  https_traffic_only_enabled        = true
  min_tls_version                   = "TLS1_2"
  infrastructure_encryption_enabled = true
  cross_tenant_replication_enabled  = false
  local_user_enabled                = false
  sftp_enabled                      = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  blob_properties {
    delete_retention_policy {
      days = var.archive_soft_delete_days
    }
    container_delete_retention_policy {
      days = var.archive_soft_delete_days
    }
  }

  tags = merge(local.tags, { Role = "syslog-archive" })
}

# Management-plane container (azurerm 4.x storage_account_id form).
resource "azurerm_storage_container" "archive" {
  count = var.enable_blob_archive ? 1 : 0

  name                  = var.archive_container_name
  storage_account_id    = azurerm_storage_account.archive[0].id
  container_access_type = "private"
}

# Optional WORM: blobs cannot be changed or deleted until they are this old.
resource "azurerm_storage_container_immutability_policy" "archive" {
  count = var.enable_blob_archive && var.archive_immutable ? 1 : 0

  storage_container_resource_manager_id = azurerm_storage_container.archive[0].id
  immutability_period_in_days           = var.blob_retention_days
  protected_append_writes_all_enabled   = false
  locked                                = false # lock only after you are happy with the period - it cannot be shortened
}

# Retention: delete archived logs blob_retention_days after upload.
resource "azurerm_storage_management_policy" "archive" {
  count = var.enable_blob_archive ? 1 : 0

  storage_account_id = azurerm_storage_account.archive[0].id

  rule {
    name    = "syslog-retention"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${var.archive_container_name}/"]
    }

    actions {
      base_blob {
        delete_after_days_since_creation_greater_than = var.blob_retention_days
      }
    }
  }
}

# Least privilege: write access on the archive container only.
resource "azurerm_role_assignment" "archive_writer" {
  for_each = var.enable_blob_archive ? local.instances : {}

  scope                = azurerm_storage_container.archive[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.syslog[each.key].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# ---------------------------------------------------------------------------
# Private endpoint. LZ integration point: most CAF landing zones create the
# privatelink.blob.core.windows.net record automatically with the
# "Deploy-Private-DNS-Zones" policy. Set blob_private_dns_zone_id only if
# yours does not.
# ---------------------------------------------------------------------------
data "azurerm_subnet" "private_endpoint" {
  count                = var.enable_blob_archive && var.private_endpoint_subnet_name != null ? 1 : 0
  provider             = azurerm.network
  name                 = var.private_endpoint_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group_name
}

resource "azurerm_private_endpoint" "archive_blob" {
  count = var.enable_blob_archive ? 1 : 0

  name                          = "pep-${local.archive_account_name}-blob"
  location                      = var.location
  resource_group_name           = local.resource_group_name
  subnet_id                     = var.private_endpoint_subnet_name != null ? data.azurerm_subnet.private_endpoint[0].id : data.azurerm_subnet.syslog.id
  custom_network_interface_name = "nic-pep-${local.archive_account_name}-blob"
  tags                          = local.tags

  private_service_connection {
    name                           = "psc-${local.archive_account_name}-blob"
    private_connection_resource_id = azurerm_storage_account.archive[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = var.blob_private_dns_zone_id == null ? [] : [1]
    content {
      name                 = "default"
      private_dns_zone_ids = [var.blob_private_dns_zone_id]
    }
  }

  # Policy-driven DNS adds a zone group outside Terraform; do not fight it.
  lifecycle {
    ignore_changes = [private_dns_zone_group]
  }
}

# Audit who wrote or deleted archived logs.
resource "azurerm_monitor_diagnostic_setting" "archive_blob" {
  count = var.enable_blob_archive && var.enable_diagnostic_settings ? 1 : 0

  name                       = "diag-to-law"
  target_resource_id         = "${azurerm_storage_account.archive[0].id}/blobServices/default"
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}
