# ---------------------------------------------------------------------------
# TLS certificate for 6514 from the Landing Zone Key Vault.
#
# The VM's system-assigned identity reads the certificate's backing secret
# (PEM: key + chain) over the vault's private endpoint at Ansible time.
# Nothing secret passes through Terraform state or the CSE payload.
# ---------------------------------------------------------------------------
locals {
  kv_tls          = var.enable_tls && var.tls_certificate_source == "keyvault"
  kv_secret_scope = var.key_vault_id == null ? null : "${var.key_vault_id}/secrets/${var.tls_keyvault_certificate_name}"
}

# Optional: self-issued, auto-renewing certificate created by Terraform.
# This is a DATA-PLANE call - Cloud Shell must reach the vault (vault firewall
# allows it, or Cloud Shell runs inside a VNet). Otherwise import/issue the
# certificate out of band and leave tls_keyvault_generate_certificate = false.
resource "azurerm_key_vault_certificate" "syslog" {
  count = local.kv_tls && var.tls_keyvault_generate_certificate ? 1 : 0

  name         = var.tls_keyvault_certificate_name
  key_vault_id = var.key_vault_id
  tags         = local.tags

  certificate_policy {
    issuer_parameters {
      name = "Self" # replace with your integrated CA issuer name for production trust
    }

    key_properties {
      exportable = true
      key_type   = "RSA"
      key_size   = 3072
      reuse_key  = false
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }

    # PEM so the VM can split key/chain with openssl - no PFX password needed.
    secret_properties {
      content_type = "application/x-pem-file"
    }

    x509_certificate_properties {
      subject            = "CN=${local.ansible_vars.rsyslog_tls_selfsigned_cn}"
      validity_in_months = 12
      key_usage          = ["digitalSignature", "keyEncipherment"]
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"] # serverAuth

      subject_alternative_names {
        dns_names = distinct(concat(
          [local.ansible_vars.rsyslog_tls_selfsigned_cn],
          [for k, v in local.instances : v.name]
        ))
      }
    }
  }
}

# Preferred: RBAC scoped to the single secret, not the whole vault.
resource "azurerm_role_assignment" "kv_secret_reader" {
  for_each = local.kv_tls && var.key_vault_authorization == "rbac" ? local.instances : {}

  scope                = local.kv_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.syslog[each.key].identity[0].principal_id
  principal_type       = "ServicePrincipal"

  depends_on = [azurerm_key_vault_certificate.syslog]
}

# Legacy vaults using access policies (vault-wide Get on secrets/certificates).
resource "azurerm_key_vault_access_policy" "syslog" {
  for_each = local.kv_tls && var.key_vault_authorization == "access_policy" ? local.instances : {}

  key_vault_id            = var.key_vault_id
  tenant_id               = data.azurerm_client_config.current.tenant_id
  object_id               = azurerm_linux_virtual_machine.syslog[each.key].identity[0].principal_id
  secret_permissions      = ["Get"]
  certificate_permissions = ["Get"]
}
