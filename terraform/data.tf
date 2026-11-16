# ---------------------------------------------------------------------------
# Existing Landing Zone resources. Nothing here is created or modified.
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

# Existing shared-services RG (only when not creating a dedicated one).
data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

# LZ integration point: hub shared-services subnet or management spoke subnet.
# The subnet's own NSG/UDR (to the hub firewall) remain owned by the platform team;
# this deployment adds a NIC-level NSG on top.
data "azurerm_subnet" "syslog" {
  provider             = azurerm.network
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group_name
}

# LZ integration point: central workspace in the management subscription.
data "azurerm_log_analytics_workspace" "this" {
  provider            = azurerm.management
  name                = var.log_analytics_workspace_name
  resource_group_name = var.log_analytics_workspace_resource_group_name
}

# LZ integration point: Private DNS zone in the connectivity subscription,
# already linked to the hub (and therefore resolvable from spokes via the
# DNS Private Resolver / hub DNS).
data "azurerm_private_dns_zone" "this" {
  count               = var.private_dns_zone_name == null ? 0 : 1
  provider            = azurerm.dns
  name                = var.private_dns_zone_name
  resource_group_name = var.private_dns_zone_resource_group_name
}
