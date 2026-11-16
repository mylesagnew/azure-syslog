# ---------------------------------------------------------------------------
# Availability: zones by default; Availability Set when the region has none.
# ---------------------------------------------------------------------------
resource "azurerm_availability_set" "syslog" {
  count = local.use_avset ? 1 : 0

  name                         = local.names.avset
  location                     = var.location
  resource_group_name          = local.resource_group_name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 5
  managed                      = true
  tags                         = local.tags
}

# ---------------------------------------------------------------------------
# Collector VMs - Ubuntu 24.04 Gen2, Trusted Launch, host encryption,
# system-assigned identity, managed boot diagnostics, no password auth.
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "syslog" {
  for_each = local.instances

  name                = each.value.name
  computer_name       = each.value.name
  location            = var.location
  resource_group_name = local.resource_group_name
  size                = var.vm_size
  zone                = each.value.zone
  availability_set_id = local.use_avset ? azurerm_availability_set.syslog[0].id : null

  network_interface_ids = [azurerm_network_interface.syslog[each.key].id]

  admin_username                  = var.admin_username
  disable_password_authentication = true
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  source_image_reference {
    publisher = var.source_image.publisher
    offer     = var.source_image.offer
    sku       = var.source_image.sku
    version   = var.source_image.version
  }

  os_disk {
    name                   = "osdisk-${local.suffix}-${each.key}"
    caching                = "ReadWrite"
    storage_account_type   = var.os_disk_type
    disk_size_gb           = var.os_disk_size_gb
    disk_encryption_set_id = var.disk_encryption_set_id
  }

  identity {
    type = "SystemAssigned"
  }

  # MCSB: Trusted Launch + encryption at host.
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = var.encryption_at_host_enabled

  # OS-level unattended-upgrades installs patches (configured by Ansible);
  # Azure Update Manager still assesses compliance.
  patch_mode            = "ImageDefault"
  patch_assessment_mode = "AutomaticByPlatform"
  provision_vm_agent    = true

  boot_diagnostics {} # managed storage account

  # Static on purpose: changing custom_data replaces the VM.
  custom_data = base64encode(file("${path.module}/templates/cloud-init.yaml"))

  tags = merge(local.tags, { Role = "syslog-collector" })

  depends_on = [terraform_data.input_guards]
}

# ---------------------------------------------------------------------------
# Dedicated log disk -> mounted at /var/log/remote by Ansible (LUN 0).
# ---------------------------------------------------------------------------
resource "azurerm_managed_disk" "logs" {
  for_each = var.data_disk_size_gb > 0 ? local.instances : {}

  name                          = "disk-${local.suffix}-${each.key}-logs"
  location                      = var.location
  resource_group_name           = local.resource_group_name
  storage_account_type          = var.data_disk_type
  create_option                 = "Empty"
  disk_size_gb                  = var.data_disk_size_gb
  zone                          = each.value.zone
  disk_encryption_set_id        = var.disk_encryption_set_id
  network_access_policy         = "DenyAll"
  public_network_access_enabled = false
  tags                          = local.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "logs" {
  for_each = var.data_disk_size_gb > 0 ? local.instances : {}

  managed_disk_id    = azurerm_managed_disk.logs[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.syslog[each.key].id
  lun                = 0
  caching            = "None" # write-heavy workload
}

# ---------------------------------------------------------------------------
# Extensions. Azure serialises extension operations per VM, so they are
# chained with depends_on to avoid "another operation in progress" errors.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_machine_extension" "ama" {
  for_each = var.enable_ama ? local.instances : {}

  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.syslog[each.key].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  tags                       = local.tags

  depends_on = [azurerm_virtual_machine_data_disk_attachment.logs]
}

resource "azurerm_virtual_machine_extension" "entra_ssh" {
  for_each = var.enable_entra_ssh_login ? local.instances : {}

  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.syslog[each.key].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  tags                       = local.tags

  depends_on = [azurerm_virtual_machine_extension.ama]
}

resource "azurerm_role_assignment" "entra_ssh_admin" {
  for_each = var.enable_entra_ssh_login ? {
    for pair in setproduct(keys(local.instances), var.entra_admin_group_object_ids) : "${pair[0]}-${pair[1]}" => {
      vm    = pair[0]
      group = pair[1]
    }
  } : {}

  scope                = azurerm_linux_virtual_machine.syslog[each.value.vm].id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = each.value.group
  principal_type       = "Group"
}

# ---------------------------------------------------------------------------
# Ansible delivery, mode "cse" (default):
#   Terraform zips ../ansible, embeds it in a bootstrap script and hands it to
#   the Custom Script Extension (protected settings = encrypted at rest).
#   The VM runs ansible-playbook against itself. No inbound path from Cloud
#   Shell is required, which suits private-only Landing Zone subnets.
#   Any change to the playbook or the vars re-runs it on the next apply.
# ---------------------------------------------------------------------------
data "archive_file" "ansible" {
  type        = "zip"
  source_dir  = "${path.module}/../ansible"
  output_path = "${path.module}/.build/ansible-bundle.zip"
  excludes    = ["inventory/generated", ".ansible", "terraform-vars.json"]
}

locals {
  ansible_vars_json = jsonencode(local.ansible_vars)
  ansible_revision  = sha1("${data.archive_file.ansible.output_sha}${local.ansible_vars_json}")

  bootstrap_script = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    bundle_b64       = filebase64(data.archive_file.ansible.output_path)
    vars_json        = local.ansible_vars_json
    revision         = local.ansible_revision
    reconverge_timer = var.ansible_reconverge_weekly
  })
}

resource "azurerm_virtual_machine_extension" "ansible" {
  for_each = var.ansible_mode == "cse" ? local.instances : {}

  name                 = "ansible-bootstrap"
  virtual_machine_id   = azurerm_linux_virtual_machine.syslog[each.key].id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"
  tags                 = local.tags

  # timestamp forces a re-run whenever the playbook or its inputs change.
  settings = jsonencode({
    timestamp = parseint(substr(local.ansible_revision, 0, 7), 16)
  })

  protected_settings = jsonencode({
    script = base64encode(local.bootstrap_script)
  })

  timeouts {
    create = "60m"
    update = "60m"
  }

  lifecycle {
    precondition {
      condition     = length(base64encode(local.bootstrap_script)) < 240000
      error_message = "Bootstrap payload is near the Custom Script Extension 256 KB limit - trim the ansible/ tree."
    }
  }

  # AMA + DCR first: AMA writes its rsyslog forwarder config once the DCR
  # arrives, and Ansible reads the AMA port from it.
  depends_on = [
    azurerm_virtual_machine_extension.ama,
    azurerm_virtual_machine_extension.entra_ssh,
    azurerm_monitor_data_collection_rule_association.syslog,
    azurerm_role_assignment.kv_secret_reader,
    azurerm_key_vault_access_policy.syslog,
    azurerm_key_vault_certificate.syslog,
  ]
}

# ---------------------------------------------------------------------------
# Ansible delivery, mode "bastion_push": local-exec from Cloud Shell through
# 'az network bastion tunnel' (Bastion Standard/Premium, native client on).
# ---------------------------------------------------------------------------
resource "null_resource" "ansible_push" {
  count = var.ansible_mode == "bastion_push" ? 1 : 0

  triggers = {
    revision = local.ansible_revision
    vms      = join(",", [for k in sort(keys(local.instances)) : azurerm_linux_virtual_machine.syslog[k].id])
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/../scripts/ansible-push-via-bastion.sh"
    environment = {
      BASTION_NAME            = var.bastion_name
      BASTION_RESOURCE_GROUP  = var.bastion_resource_group_name
      BASTION_SUBSCRIPTION_ID = local.bastion_subscription_id
      VM_IDS                  = join(",", [for k in sort(keys(local.instances)) : azurerm_linux_virtual_machine.syslog[k].id])
      ADMIN_USERNAME          = var.admin_username
      SSH_PRIVATE_KEY         = pathexpand(var.ssh_private_key_path)
      EXTRA_VARS_JSON         = local.ansible_vars_json
    }
  }

  depends_on = [
    azurerm_virtual_machine_extension.ama,
    azurerm_virtual_machine_extension.entra_ssh,
    azurerm_monitor_data_collection_rule_association.syslog,
    azurerm_role_assignment.kv_secret_reader,
    azurerm_key_vault_access_policy.syslog,
    azurerm_key_vault_certificate.syslog,
    azurerm_network_security_rule.ssh,
  ]
}
