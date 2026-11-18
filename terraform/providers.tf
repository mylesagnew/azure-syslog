# ---------------------------------------------------------------------------
# Landing Zone integration point: subscriptions
#
# CAF landing zones split resources across subscriptions. Four provider
# instances are used so each existing resource is read from where it lives:
#
#   default       -> workload subscription that will host the syslog VMs
#                    (shared services / identity / management - your choice)
#   network       -> subscription holding the VNet/subnet (hub or spoke)
#   dns           -> connectivity subscription holding the Private DNS zones
#   management    -> management subscription holding Log Analytics / Sentinel
#
# Any alias left null falls back to the workload subscription.
# In Cloud Shell the identity is the signed-in user (az login is implicit).
# ---------------------------------------------------------------------------

provider "azurerm" {
  subscription_id = var.subscription_id
  # Landing zone policies usually stop workload identities registering RPs.
  resource_provider_registrations = var.resource_provider_registrations
  storage_use_azuread             = true

  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
    key_vault {
      # Never purge shared Landing Zone vault content on destroy.
      purge_soft_delete_on_destroy               = false
      purge_soft_deleted_certificates_on_destroy = false
      recover_soft_deleted_certificates          = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    storage {
      # The archive account is private-endpoint only; Cloud Shell cannot reach its data plane.
      data_plane_available = false
    }
  }
}

provider "azurerm" {
  alias                           = "network"
  subscription_id                 = coalesce(var.network_subscription_id, var.subscription_id)
  resource_provider_registrations = "none"
  features {}
}

provider "azurerm" {
  alias                           = "dns"
  subscription_id                 = coalesce(var.dns_subscription_id, var.subscription_id)
  resource_provider_registrations = "none"
  features {}
}

provider "azurerm" {
  alias                           = "management"
  subscription_id                 = coalesce(var.management_subscription_id, var.subscription_id)
  resource_provider_registrations = "none"
  features {}
}
