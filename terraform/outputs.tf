output "resource_group_name" {
  value = local.resource_group_name
}

output "syslog_endpoint_ip" {
  description = "IP that syslog senders should target (LB frontend, or the single VM)."
  value       = local.syslog_endpoint_ip
}

output "syslog_dns_name" {
  description = "Recommended DNS name for senders."
  value       = local.syslog_fqdn
}

output "collector_private_ips" {
  description = "Private IP of each collector VM."
  value       = { for k, v in azurerm_network_interface.syslog : azurerm_linux_virtual_machine.syslog[k].name => v.private_ip_address }
}

output "collector_vm_ids" {
  value = { for k, v in azurerm_linux_virtual_machine.syslog : v.name => v.id }
}

output "collector_principal_ids" {
  description = "System-assigned managed identity object IDs."
  value       = { for k, v in azurerm_linux_virtual_machine.syslog : v.name => v.identity[0].principal_id }
}

output "application_security_group_id" {
  description = "Reference this ASG in hub firewall / subnet NSG rules."
  value       = azurerm_application_security_group.syslog.id
}

output "data_collection_rule_id" {
  value = try(azurerm_monitor_data_collection_rule.syslog[0].id, null)
}

output "bastion_ssh_commands" {
  description = "SSH via Bastion native client (Standard/Premium SKU)."
  value = var.bastion_name == null ? {} : {
    for k, v in azurerm_linux_virtual_machine.syslog : v.name => join(" ", [
      "az network bastion ssh",
      "--name ${var.bastion_name}",
      "--resource-group ${var.bastion_resource_group_name}",
      "--subscription ${local.bastion_subscription_id}",
      "--target-resource-id ${v.id}",
      "--auth-type ${var.enable_entra_ssh_login ? "AAD" : "ssh-key --username ${var.admin_username} --ssh-key ${var.ssh_private_key_path}"}",
    ])
  }
}

output "test_commands" {
  description = "Run from a host inside syslog_allowed_source_cidrs."
  value = {
    udp       = "logger --server ${local.syslog_endpoint_ip} --port 514 --udp 'lz-syslog-test udp'"
    tcp       = "logger --server ${local.syslog_endpoint_ip} --port 514 --tcp 'lz-syslog-test tcp'"
    tls       = var.enable_tls ? "openssl s_client -connect ${local.syslog_endpoint_ip}:6514 -brief </dev/null" : "TLS disabled"
    nc_udp    = "echo '<134>lz-syslog-test nc-udp' | nc -u -w1 ${local.syslog_endpoint_ip} 514"
    kql       = "Syslog | where TimeGenerated > ago(30m) | where SyslogMessage has 'lz-syslog-test' | project TimeGenerated, HostName, HostIP, Facility, SeverityLevel, SyslogMessage"
    selfcheck = "../scripts/validate.sh   # runs checks on every collector via az vm run-command"
  }
}

output "ansible_extra_vars" {
  description = "Inputs for running Ansible manually (ansible_mode = none): terraform output -json ansible_extra_vars > ../ansible/terraform-vars.json"
  value       = local.ansible_vars
}

output "ansible_bootstrap_log" {
  value = var.ansible_mode == "cse" ? "/var/log/syslog-lz-bootstrap.log on each collector (CSE stdout also in /var/lib/waagent/custom-script/download/0/)" : null
}
