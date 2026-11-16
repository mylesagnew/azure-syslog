# ---------------------------------------------------------------------------
# Data Collection Rule: syslog received by rsyslog -> local AMA -> workspace.
#   Microsoft-Syslog            -> Syslog table           (Sentinel "Syslog via AMA")
#   Microsoft-CommonSecurityLog -> CommonSecurityLog table (Sentinel "CEF via AMA")
# The DCR must live in the workspace's region; it is placed in the collector RG.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_data_collection_rule" "syslog" {
  count = var.enable_ama && var.enable_dcr ? 1 : 0

  name                = local.names.dcr
  resource_group_name = local.resource_group_name
  location            = data.azurerm_log_analytics_workspace.this.location
  kind                = "Linux"
  description         = "Central syslog collector: forward received syslog to ${var.log_analytics_workspace_name}"
  tags                = local.tags

  destinations {
    log_analytics {
      name                  = "law-central"
      workspace_resource_id = data.azurerm_log_analytics_workspace.this.id
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["law-central"]
  }

  dynamic "data_flow" {
    for_each = length(var.dcr_cef_facilities) > 0 ? [1] : []
    content {
      streams      = ["Microsoft-CommonSecurityLog"]
      destinations = ["law-central"]
    }
  }

  data_sources {
    syslog {
      name           = "syslog-remote"
      streams        = ["Microsoft-Syslog"]
      facility_names = var.dcr_syslog_facilities
      log_levels     = var.dcr_syslog_log_levels
    }

    dynamic "syslog" {
      for_each = length(var.dcr_cef_facilities) > 0 ? [1] : []
      content {
        name           = "cef-remote"
        streams        = ["Microsoft-CommonSecurityLog"]
        facility_names = var.dcr_cef_facilities
        log_levels     = ["*"]
      }
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "syslog" {
  for_each = var.enable_ama && var.enable_dcr ? local.instances : {}

  name                    = "dcra-${local.suffix}-${each.key}"
  target_resource_id      = azurerm_linux_virtual_machine.syslog[each.key].id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.syslog[0].id
  description             = "Syslog collector -> ${var.log_analytics_workspace_name}"

  depends_on = [azurerm_virtual_machine_extension.ama]
}

# ---------------------------------------------------------------------------
# Diagnostic settings -> central workspace.
# (VNet flow logs replace NSG flow logs and are normally owned by the
#  platform team at VNet scope, so they are not created here.)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "nsg" {
  count = var.enable_diagnostic_settings ? 1 : 0

  name                       = "diag-to-law"
  target_resource_id         = azurerm_network_security_group.syslog.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "NetworkSecurityGroupEvent"
  }
  enabled_log {
    category = "NetworkSecurityGroupRuleCounter"
  }
}

resource "azurerm_monitor_diagnostic_setting" "vm" {
  for_each = var.enable_diagnostic_settings ? local.instances : {}

  name                       = "diag-to-law"
  target_resource_id         = azurerm_linux_virtual_machine.syslog[each.key].id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "nic" {
  for_each = var.enable_diagnostic_settings ? local.instances : {}

  name                       = "diag-to-law"
  target_resource_id         = azurerm_network_interface.syslog[each.key].id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "lb" {
  count = var.enable_diagnostic_settings && local.lb_enabled ? 1 : 0

  name                       = "diag-to-law"
  target_resource_id         = azurerm_lb.syslog[0].id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id

  enabled_metric {
    category = "AllMetrics"
  }
}
