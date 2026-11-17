locals {
  suffix = "${var.workload}-${var.environment}-${var.location_short}"

  names = {
    rg    = coalesce(var.resource_group_name, "rg-${local.suffix}-001")
    nsg   = "nsg-${local.suffix}-001"
    asg   = "asg-${local.suffix}-001"
    lb    = "lbi-${local.suffix}-001"
    avset = "avail-${local.suffix}-001"
    dcr   = "dcr-${local.suffix}-001"
  }

  environment_long = lookup({
    prd    = "Production"
    nonprd = "Non-Production"
    dev    = "Development"
    tst    = "Test"
    uat    = "UAT"
  }, var.environment, var.environment)

  # Standard Landing Zone tags. Organisation tags (var.tags) win on conflict.
  tags = merge({
    Environment        = local.environment_long
    Workload           = var.workload
    LandingZone        = var.landing_zone_name
    DataClassification = var.data_classification
    Criticality        = var.environment == "prd" ? "High" : "Medium"
    ManagedBy          = "Terraform"
    Repository         = "azure-syslog"
  }, var.tags)

  resource_group_name = var.create_resource_group ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name

  # One entry per collector, spread round-robin over the zones.
  instances = {
    for i in range(var.vm_count) : format("%02d", i + 1) => {
      name       = "vm-${local.suffix}-${format("%02d", i + 1)}"
      zone       = length(var.zones) > 0 ? var.zones[i % length(var.zones)] : null
      private_ip = try(var.private_ip_addresses[i], null)
    }
  }

  use_avset  = length(var.zones) == 0
  lb_enabled = var.enable_internal_load_balancer

  ssh_cidrs = distinct(concat(var.ssh_allowed_source_cidrs, var.enable_public_ip ? var.public_ip_ssh_allowed_cidrs : []))

  syslog_ports = concat(
    [
      { name = "syslog-udp-514", protocol = "Udp", port = 514 },
      { name = "syslog-tcp-514", protocol = "Tcp", port = 514 },
    ],
    var.enable_tls ? [{ name = "syslog-tls-6514", protocol = "Tcp", port = 6514 }] : []
  )

  key_vault_name = var.key_vault_id == null ? "" : element(split("/", var.key_vault_id), 8)

  # Endpoint senders should use: LB frontend if present, otherwise the first VM.
  syslog_endpoint_ip = local.lb_enabled ? azurerm_lb.syslog[0].frontend_ip_configuration[0].private_ip_address : azurerm_network_interface.syslog["01"].private_ip_address

  syslog_fqdn = var.private_dns_zone_name == null ? "${var.dns_record_name}.<your-private-zone>" : "${var.dns_record_name}.${var.private_dns_zone_name}"

  bastion_subscription_id = coalesce(var.bastion_subscription_id, var.dns_subscription_id, var.subscription_id)

  # Everything Ansible needs from the infrastructure layer. No secrets in here.
  ansible_vars = {
    required_ubuntu_release          = var.required_ubuntu_release
    baseline_ubuntu_pro              = var.ubuntu_pro
    baseline_ubuntu_pro_services     = var.ubuntu_pro_services
    syslog_allowed_source_cidrs      = var.syslog_allowed_source_cidrs
    baseline_ssh_allowed_cidrs       = local.ssh_cidrs
    baseline_unattended_reboot       = var.unattended_upgrades_auto_reboot
    baseline_unattended_reboot_time  = var.unattended_upgrades_reboot_time
    rsyslog_tls_enabled              = var.enable_tls
    rsyslog_tls_source               = var.tls_certificate_source
    rsyslog_tls_auth_mode            = var.tls_auth_mode
    rsyslog_tls_keyvault_name        = local.key_vault_name
    rsyslog_tls_keyvault_secret_name = var.tls_keyvault_certificate_name
    rsyslog_tls_selfsigned_cn        = var.private_dns_zone_name == null ? var.dns_record_name : "${var.dns_record_name}.${var.private_dns_zone_name}"
    rsyslog_lb_probe_enabled         = local.lb_enabled
    rsyslog_forward_to_ama           = var.enable_ama && var.enable_dcr && var.rsyslog_forward_to_ama
    rsyslog_forward_targets          = var.rsyslog_forward_targets
    rsyslog_remote_retention_days    = var.remote_log_retention_days
    rsyslog_remote_file_format       = var.remote_log_format
    syslog_data_disk_lun             = var.data_disk_size_gb > 0 ? 0 : null
  }
}
