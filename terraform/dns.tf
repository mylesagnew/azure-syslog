# ---------------------------------------------------------------------------
# Private DNS records in the connectivity subscription.
#   syslog.<zone>     -> LB frontend (or the only VM)  <- what senders use
#   vm-...-NN.<zone>  -> each collector, for admin / troubleshooting
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_a_record" "endpoint" {
  count    = var.private_dns_zone_name == null ? 0 : 1
  provider = azurerm.dns

  name                = var.dns_record_name
  zone_name           = data.azurerm_private_dns_zone.this[0].name
  resource_group_name = var.private_dns_zone_resource_group_name
  ttl                 = 300
  records             = [local.syslog_endpoint_ip]
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "instance" {
  for_each = var.private_dns_zone_name == null ? {} : local.instances
  provider = azurerm.dns

  name                = each.value.name
  zone_name           = data.azurerm_private_dns_zone.this[0].name
  resource_group_name = var.private_dns_zone_resource_group_name
  ttl                 = 300
  records             = [azurerm_network_interface.syslog[each.key].private_ip_address]
  tags                = local.tags
}
