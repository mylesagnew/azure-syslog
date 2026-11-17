# ===========================================================================
# Subscriptions & provider behaviour
# ===========================================================================
variable "subscription_id" {
  description = "Workload subscription that hosts the syslog collector(s)."
  type        = string
}

variable "network_subscription_id" {
  description = "Subscription containing the target VNet/subnet. null = workload subscription."
  type        = string
  default     = null
}

variable "dns_subscription_id" {
  description = "Connectivity subscription containing the Private DNS zone. null = workload subscription."
  type        = string
  default     = null
}

variable "management_subscription_id" {
  description = "Management subscription containing Log Analytics / Sentinel. null = workload subscription."
  type        = string
  default     = null
}

variable "resource_provider_registrations" {
  description = "azurerm RP auto-registration set. 'none' suits Landing Zones where RPs are pre-registered by the platform team."
  type        = string
  default     = "none"
}

# ===========================================================================
# Naming & tagging (CAF: <type>-<workload>-<env>-<region>-<instance>)
# ===========================================================================
variable "location" {
  description = "Azure region for the collector."
  type        = string
  default     = "australiaeast"
}

variable "location_short" {
  description = "Short region code used in names (e.g. aue, ause, eus2)."
  type        = string
  default     = "aue"
}

variable "environment" {
  description = "Environment code used in names (prd, nonprd, dev, tst)."
  type        = string
  default     = "prd"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.environment))
    error_message = "environment must be 2-8 lowercase alphanumerics."
  }
}

variable "workload" {
  description = "Workload code used in names."
  type        = string
  default     = "syslog"
}

variable "landing_zone_name" {
  description = "Value for the LandingZone tag (e.g. 'platform-management', 'corp')."
  type        = string
}

variable "tags" {
  description = "Organisation tags. Must include Owner and CostCenter; merged over the standard tags."
  type        = map(string)

  validation {
    condition     = contains(keys(var.tags), "Owner") && contains(keys(var.tags), "CostCenter")
    error_message = "tags must contain at least Owner and CostCenter."
  }
}

variable "data_classification" {
  description = "DataClassification tag. Syslog commonly carries security-relevant data."
  type        = string
  default     = "Confidential"
}

# ===========================================================================
# Resource group
# ===========================================================================
variable "create_resource_group" {
  description = "true = create a dedicated RG; false = deploy into an existing shared-services RG."
  type        = bool
  default     = true
}

variable "resource_group_name" {
  description = "RG name. Required when create_resource_group = false; otherwise overrides the generated name."
  type        = string
  default     = null
}

# ===========================================================================
# Networking (existing Landing Zone resources)
# ===========================================================================
variable "vnet_name" {
  description = "Existing VNet (hub shared-services subnet or a management spoke)."
  type        = string
}

variable "vnet_resource_group_name" {
  description = "Resource group of the existing VNet."
  type        = string
}

variable "subnet_name" {
  description = "Existing subnet for the collector NICs (and the internal LB frontend)."
  type        = string
}

variable "private_ip_addresses" {
  description = "Optional static private IPs, one per VM in order. Empty = dynamic allocation."
  type        = list(string)
  default     = []
}

variable "syslog_allowed_source_cidrs" {
  description = "CIDRs allowed to send syslog (UDP/TCP 514, TLS 6514). Keep to Landing Zone ranges."
  type        = list(string)

  validation {
    condition = length(var.syslog_allowed_source_cidrs) > 0 && alltrue([
      for c in var.syslog_allowed_source_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"
    ])
    error_message = "Provide at least one valid CIDR; 0.0.0.0/0 is not allowed."
  }
}

variable "ssh_allowed_source_cidrs" {
  description = "CIDRs allowed to SSH (normally only the AzureBastionSubnet prefix)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.ssh_allowed_source_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "ssh_allowed_source_cidrs must be valid CIDRs and must not be 0.0.0.0/0."
  }
}

variable "enable_internal_load_balancer" {
  description = "Front the collectors with a zone-redundant internal Standard LB (recommended when vm_count > 1)."
  type        = bool
  default     = false
}

variable "lb_private_ip_address" {
  description = "Optional static frontend IP for the internal LB. null = dynamic."
  type        = string
  default     = null
}

variable "enable_public_ip" {
  description = "Attach a Standard public IP for SSH ONLY when no Bastion is available. Syslog is never exposed publicly."
  type        = bool
  default     = false
}

variable "public_ip_ssh_allowed_cidrs" {
  description = "Public CIDRs allowed to SSH when enable_public_ip = true."
  type        = list(string)
  default     = []
}

# ===========================================================================
# Private DNS (connectivity subscription)
# ===========================================================================
variable "private_dns_zone_name" {
  description = "Existing Private DNS zone for the A record (e.g. 'internal.contoso.com'). null = skip record."
  type        = string
  default     = null
}

variable "private_dns_zone_resource_group_name" {
  description = "Resource group of the Private DNS zone."
  type        = string
  default     = null
}

variable "dns_record_name" {
  description = "A record name for the collector endpoint."
  type        = string
  default     = "syslog"
}

# ===========================================================================
# Compute
# ===========================================================================
variable "vm_count" {
  description = "Number of collectors. They are spread across var.zones."
  type        = number
  default     = 1

  validation {
    condition     = var.vm_count >= 1 && var.vm_count <= 5
    error_message = "vm_count must be between 1 and 5."
  }
}

variable "vm_size" {
  description = "VM SKU. D2as_v5/D2s_v5 for steady ingest; B2s_v2 only for low, bursty volumes."
  type        = string
  default     = "Standard_D2as_v5"
}

variable "zones" {
  description = "Availability Zones to spread VMs across. Empty list = Availability Set instead."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "source_image" {
  description = "Ubuntu 26.04 LTS Gen2 marketplace image (URN Canonical:ubuntu-26_04-lts:server:latest). The offer is Canonical's unified 26.04 offer: sku 'server' = Ubuntu Server (AMD64, Gen2); for Ubuntu Pro prefer var.ubuntu_pro (in-place licence upgrade) over changing the SKU, which would replace the VM. 'latest' resolves to a 26.04.1+ build; Ansible enforces required_ubuntu_release."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-26_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

variable "ubuntu_pro" {
  description = <<-EOT
    Upgrade the collectors to Ubuntu Pro in place: sets the VM license type to UBUNTU_PRO
    (billed per VM hour by Azure) and Ansible runs 'pro auto-attach'. Livepatch, ESM and the
    USG CIS tooling become available. No redeploy - the image stays the free 'server' SKU.
  EOT
  type        = bool
  default     = false
}

variable "ubuntu_pro_services" {
  description = "Ubuntu Pro services to make sure are enabled after attach (Azure auto-enables esm-infra/esm-apps/livepatch by default)."
  type        = list(string)
  default     = ["esm-infra", "esm-apps", "livepatch"]
}

variable "required_ubuntu_release" {
  description = "Minimum Ubuntu point release the playbook accepts (checked against /etc/os-release VERSION)."
  type        = string
  default     = "26.04.1"

  validation {
    condition     = can(regex("^26\\.04(\\.[0-9]+)?$", var.required_ubuntu_release))
    error_message = "required_ubuntu_release must be a 26.04.x release, e.g. 26.04.1."
  }
}

variable "admin_username" {
  description = "Local admin user (SSH key only)."
  type        = string
  default     = "azureadmin"
}

variable "admin_ssh_public_key" {
  description = "SSH public key content (not a path). Pass via TF_VAR_admin_ssh_public_key."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Private key path in Cloud Shell. Only used by ansible_mode = 'bastion_push'."
  type        = string
  default     = "~/.ssh/syslog_admin"
}

variable "os_disk_type" {
  type    = string
  default = "Premium_LRS"
}

variable "os_disk_size_gb" {
  type    = number
  default = 64
}

variable "data_disk_size_gb" {
  description = "Dedicated data disk for /var/log/remote. 0 = keep logs on the OS disk (not recommended)."
  type        = number
  default     = 128
}

variable "data_disk_type" {
  type    = string
  default = "Premium_LRS"
}

variable "encryption_at_host_enabled" {
  description = "Encrypt temp disk, caches and data in transit to storage (requires the EncryptionAtHost feature on the subscription)."
  type        = bool
  default     = true
}

variable "disk_encryption_set_id" {
  description = "Optional Disk Encryption Set (customer-managed key) for OS and data disks. null = platform-managed keys."
  type        = string
  default     = null
}

variable "accelerated_networking_enabled" {
  type    = bool
  default = true
}

variable "enable_entra_ssh_login" {
  description = "Install AADSSHLoginForLinux so admins sign in with Entra ID through Bastion."
  type        = bool
  default     = false
}

variable "entra_admin_group_object_ids" {
  description = "Entra groups granted 'Virtual Machine Administrator Login' on the collectors."
  type        = list(string)
  default     = []
}

variable "unattended_upgrades_auto_reboot" {
  description = "Allow unattended-upgrades to reboot. Keep false for single-VM deployments."
  type        = bool
  default     = false
}

variable "unattended_upgrades_reboot_time" {
  type    = string
  default = "03:30"
}

# ===========================================================================
# Configuration management
# ===========================================================================
variable "ansible_mode" {
  description = <<-EOT
    How Ansible is run:
      cse          - Terraform ships the playbook through the Custom Script Extension and it runs
                     locally on the VM (no network path from Cloud Shell needed). Default.
      bastion_push - null_resource/local-exec runs ansible-playbook from Cloud Shell over
                     'az network bastion tunnel' (Bastion Standard/Premium with native client).
      none         - infrastructure only; run Ansible yourself.
  EOT
  type        = string
  default     = "cse"

  validation {
    condition     = contains(["cse", "bastion_push", "none"], var.ansible_mode)
    error_message = "ansible_mode must be cse, bastion_push or none."
  }
}

variable "bastion_name" {
  description = "Existing Azure Bastion host (used for outputs and bastion_push)."
  type        = string
  default     = null
}

variable "bastion_resource_group_name" {
  type    = string
  default = null
}

variable "bastion_subscription_id" {
  description = "Subscription of the Bastion host. null = dns_subscription_id, then workload."
  type        = string
  default     = null
}

variable "ansible_reconverge_weekly" {
  description = "CSE mode: install a weekly systemd timer that re-applies the playbook to correct drift."
  type        = bool
  default     = true
}

# ===========================================================================
# rsyslog behaviour (passed to Ansible)
# ===========================================================================
variable "enable_tls" {
  description = "Open TLS syslog on TCP/6514."
  type        = bool
  default     = true
}

variable "tls_certificate_source" {
  description = "'keyvault' = VM reads a PEM certificate from Key Vault with its managed identity; 'selfsigned' = generated on the VM."
  type        = string
  default     = "selfsigned"

  validation {
    condition     = contains(["keyvault", "selfsigned"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be keyvault or selfsigned."
  }
}

variable "tls_auth_mode" {
  description = "rsyslog gtls authMode for 6514: anon (encrypt only), x509/certvalid or x509/name (mutual TLS)."
  type        = string
  default     = "anon"

  validation {
    condition     = contains(["anon", "x509/certvalid", "x509/name"], var.tls_auth_mode)
    error_message = "tls_auth_mode must be anon, x509/certvalid or x509/name."
  }
}

variable "key_vault_id" {
  description = "Resource ID of the existing Landing Zone Key Vault (needed when tls_certificate_source = keyvault)."
  type        = string
  default     = null
}

variable "key_vault_authorization" {
  description = "'rbac' (role on the single secret - preferred) or 'access_policy' for legacy vaults."
  type        = string
  default     = "rbac"

  validation {
    condition     = contains(["rbac", "access_policy"], var.key_vault_authorization)
    error_message = "key_vault_authorization must be rbac or access_policy."
  }
}

variable "tls_keyvault_certificate_name" {
  description = "Key Vault certificate name. Its secret must have content type application/x-pem-file."
  type        = string
  default     = "syslog-collector-tls"
}

variable "tls_keyvault_generate_certificate" {
  description = "Have Terraform create a self-issued, auto-renewing certificate in Key Vault. Needs data-plane reach from Cloud Shell (see README)."
  type        = bool
  default     = false
}

variable "rsyslog_forward_to_ama" {
  description = "Forward received remote events to the local Azure Monitor Agent (-> Log Analytics / Sentinel)."
  type        = bool
  default     = true
}

variable "rsyslog_forward_targets" {
  description = "Extra downstream forwarders (SIEM, second collector)."
  type = list(object({
    name           = string
    target         = string
    port           = number
    protocol       = string # udp | tcp
    tls            = optional(bool, false)
    permitted_peer = optional(string, "")
    filter         = optional(string, "*.*")
  }))
  default = []
}

variable "remote_log_retention_days" {
  description = "Days of on-disk remote logs kept by logrotate."
  type        = number
  default     = 30
}

variable "remote_log_format" {
  description = "On-disk format for remote logs: traditional | rfc5424 | json."
  type        = string
  default     = "traditional"

  validation {
    condition     = contains(["traditional", "rfc5424", "json"], var.remote_log_format)
    error_message = "remote_log_format must be traditional, rfc5424 or json."
  }
}

# ===========================================================================
# Monitoring / Sentinel (management subscription)
# ===========================================================================
variable "log_analytics_workspace_name" {
  description = "Existing Log Analytics workspace (Sentinel-enabled if you use Sentinel)."
  type        = string
}

variable "log_analytics_workspace_resource_group_name" {
  type = string
}

variable "enable_ama" {
  description = "Install the Azure Monitor Agent extension."
  type        = bool
  default     = true
}

variable "enable_dcr" {
  description = "Create a Data Collection Rule sending Syslog to the workspace and associate it with the VMs."
  type        = bool
  default     = true
}

variable "dcr_syslog_facilities" {
  description = "Facilities sent to the Syslog table. Do not overlap with dcr_cef_facilities."
  type        = list(string)
  default     = ["auth", "authpriv", "cron", "daemon", "kern", "syslog", "user", "local0", "local1", "local2", "local3", "local5", "local6", "local7"]
}

variable "dcr_syslog_log_levels" {
  description = "Severities collected. Dropping Debug/Info is the biggest Log Analytics cost lever."
  type        = list(string)
  default     = ["Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
}

variable "dcr_cef_facilities" {
  description = "Facilities parsed as CEF into CommonSecurityLog (Sentinel 'CEF via AMA'). Empty = no CEF stream."
  type        = list(string)
  default     = []
}

variable "enable_diagnostic_settings" {
  description = "Send NSG logs and platform metrics (VM, NIC, LB) to the workspace."
  type        = bool
  default     = true
}
