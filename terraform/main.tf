# ---------------------------------------------------------------------------
# Resource group + input guards
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = local.names.rg
  location = var.location
  tags     = local.tags
}

# Cross-variable checks that a single variable validation cannot express.
resource "terraform_data" "input_guards" {
  input = var.ansible_mode

  lifecycle {
    precondition {
      condition     = var.create_resource_group || var.resource_group_name != null
      error_message = "resource_group_name is required when create_resource_group = false."
    }
    precondition {
      condition     = !(var.enable_tls && var.tls_certificate_source == "keyvault") || var.key_vault_id != null
      error_message = "key_vault_id is required when tls_certificate_source = keyvault."
    }
    precondition {
      condition     = var.ansible_mode != "bastion_push" || (var.bastion_name != null && var.bastion_resource_group_name != null && length(var.ssh_allowed_source_cidrs) > 0)
      error_message = "bastion_push needs bastion_name, bastion_resource_group_name and the AzureBastionSubnet CIDR in ssh_allowed_source_cidrs."
    }
    precondition {
      condition     = !var.enable_public_ip || length(var.public_ip_ssh_allowed_cidrs) > 0
      error_message = "enable_public_ip = true requires public_ip_ssh_allowed_cidrs (SSH is never opened to the internet)."
    }
    precondition {
      condition     = length(var.private_ip_addresses) == 0 || length(var.private_ip_addresses) == var.vm_count
      error_message = "private_ip_addresses must be empty or have exactly vm_count entries."
    }
    precondition {
      condition     = length(setintersection(var.dcr_syslog_facilities, var.dcr_cef_facilities)) == 0
      error_message = "dcr_syslog_facilities and dcr_cef_facilities must not overlap (duplicate ingestion)."
    }
  }
}
