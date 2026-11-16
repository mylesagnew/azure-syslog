# ---------------------------------------------------------------------------
# Application Security Group - lets the platform team write hub firewall /
# subnet NSG rules against "the syslog collectors" instead of raw IPs.
# ---------------------------------------------------------------------------
resource "azurerm_application_security_group" "syslog" {
  name                = local.names.asg
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# NIC-level NSG (least privilege). The subnet NSG owned by the Landing Zone
# still applies; traffic must be allowed by both.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "syslog" {
  name                = local.names.nsg
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "syslog" {
  for_each = { for idx, p in local.syslog_ports : p.name => merge(p, { priority = 200 + idx * 10 }) }

  name                                       = "Allow-${each.key}-Inbound"
  description                                = "Syslog from approved Landing Zone source ranges only"
  priority                                   = each.value.priority
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = each.value.protocol
  source_port_range                          = "*"
  destination_port_range                     = tostring(each.value.port)
  source_address_prefixes                    = var.syslog_allowed_source_cidrs
  destination_application_security_group_ids = [azurerm_application_security_group.syslog.id]
  resource_group_name                        = local.resource_group_name
  network_security_group_name                = azurerm_network_security_group.syslog.name
}

resource "azurerm_network_security_rule" "ssh" {
  count = length(local.ssh_cidrs) > 0 ? 1 : 0

  name                                       = "Allow-SSH-Bastion-Inbound"
  description                                = "SSH from Azure Bastion (and explicit admin ranges) only"
  priority                                   = 300
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "22"
  source_address_prefixes                    = local.ssh_cidrs
  destination_application_security_group_ids = [azurerm_application_security_group.syslog.id]
  resource_group_name                        = local.resource_group_name
  network_security_group_name                = azurerm_network_security_group.syslog.name
}

resource "azurerm_network_security_rule" "lb_probe" {
  count = local.lb_enabled ? 1 : 0

  name                                       = "Allow-AzureLoadBalancer-Probe-Inbound"
  priority                                   = 310
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "514"
  source_address_prefix                      = "AzureLoadBalancer"
  destination_application_security_group_ids = [azurerm_application_security_group.syslog.id]
  resource_group_name                        = local.resource_group_name
  network_security_group_name                = azurerm_network_security_group.syslog.name
}

# Explicit deny overrides the default AllowVnetInBound (65000) rule.
resource "azurerm_network_security_rule" "deny_all_inbound" {
  name                        = "Deny-All-Inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.syslog.name
}

# ---------------------------------------------------------------------------
# Optional public IP - break-glass SSH only, when no Bastion exists.
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "syslog" {
  for_each = var.enable_public_ip ? local.instances : {}

  name                = "pip-${local.suffix}-${each.key}"
  location            = var.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = each.value.zone == null ? null : [each.value.zone]
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# NICs - private only by default.
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "syslog" {
  for_each = local.instances

  name                           = "nic-${local.suffix}-${each.key}"
  location                       = var.location
  resource_group_name            = local.resource_group_name
  accelerated_networking_enabled = var.accelerated_networking_enabled
  tags                           = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = data.azurerm_subnet.syslog.id
    private_ip_address_allocation = each.value.private_ip == null ? "Dynamic" : "Static"
    private_ip_address            = each.value.private_ip
    public_ip_address_id          = var.enable_public_ip ? azurerm_public_ip.syslog[each.key].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "syslog" {
  for_each = local.instances

  network_interface_id      = azurerm_network_interface.syslog[each.key].id
  network_security_group_id = azurerm_network_security_group.syslog.id
}

resource "azurerm_network_interface_application_security_group_association" "syslog" {
  for_each = local.instances

  network_interface_id          = azurerm_network_interface.syslog[each.key].id
  application_security_group_id = azurerm_application_security_group.syslog.id
}

# ---------------------------------------------------------------------------
# Optional zone-redundant internal Standard Load Balancer.
# Client source IPs are preserved, so per-sender log separation still works.
# ---------------------------------------------------------------------------
resource "azurerm_lb" "syslog" {
  count = local.lb_enabled ? 1 : 0

  name                = local.names.lb
  location            = var.location
  resource_group_name = local.resource_group_name
  sku                 = "Standard"
  tags                = local.tags

  frontend_ip_configuration {
    name                          = "fe-syslog"
    subnet_id                     = data.azurerm_subnet.syslog.id
    private_ip_address_allocation = var.lb_private_ip_address == null ? "Dynamic" : "Static"
    private_ip_address            = var.lb_private_ip_address
    zones                         = length(var.zones) > 0 ? var.zones : null
  }
}

resource "azurerm_lb_backend_address_pool" "syslog" {
  count           = local.lb_enabled ? 1 : 0
  name            = "be-syslog"
  loadbalancer_id = azurerm_lb.syslog[0].id
}

resource "azurerm_lb_probe" "syslog" {
  count               = local.lb_enabled ? 1 : 0
  name                = "probe-tcp-514"
  loadbalancer_id     = azurerm_lb.syslog[0].id
  protocol            = "Tcp"
  port                = 514
  interval_in_seconds = 5
}

resource "azurerm_lb_rule" "syslog" {
  for_each = local.lb_enabled ? { for p in local.syslog_ports : p.name => p } : {}

  name                           = each.key
  loadbalancer_id                = azurerm_lb.syslog[0].id
  protocol                       = each.value.protocol
  frontend_port                  = each.value.port
  backend_port                   = each.value.port
  frontend_ip_configuration_name = "fe-syslog"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.syslog[0].id]
  probe_id                       = azurerm_lb_probe.syslog[0].id
  disable_outbound_snat          = true
  idle_timeout_in_minutes        = 30
  tcp_reset_enabled              = each.value.protocol == "Tcp"
}

resource "azurerm_network_interface_backend_address_pool_association" "syslog" {
  for_each = local.lb_enabled ? local.instances : {}

  network_interface_id    = azurerm_network_interface.syslog[each.key].id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.syslog[0].id
}
