#!/usr/bin/env bash
# Interactive installer for the azure-syslog collector. Run in Azure Cloud Shell (bash):
#
#   ./scripts/install.sh              # ask questions, write tfvars, plan, confirm, apply
#   ./scripts/install.sh --plan-only  # stop after 'terraform plan'
#
# It looks up your Landing Zone resources with az, asks for the IP ranges
# (syslog senders, Bastion, optional static IPs) and validates every address,
# then writes terraform/terraform.tfvars and terraform/backend.hcl.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLAN_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --plan-only) PLAN_ONLY=true ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done

hdr "Preflight"
require_tools az terraform python3 ssh-keygen
require_login
CUR_SUB=$(az account show --query id -o tsv)
ok "Signed in as $(az account show --query user.name -o tsv) (subscription $(az account show --query name -o tsv))"

ASK=true
if [ -f "$TFVARS" ]; then
  ask_yn REUSE "terraform/terraform.tfvars already exists. Reuse it and skip the questions?" y
  [ "$REUSE" = true ] && ASK=false
fi

if [ "$ASK" = true ]; then
  # ------------------------------------------------------------------ subscriptions
  hdr "1/9 Subscriptions"
  az account list --query "[].{Name:name, Id:id}" -o table
  ask_required SUB_ID   "Workload subscription (hosts the collectors)" "$CUR_SUB"
  ask_required NET_SUB  "Subscription of the VNet/subnet (hub or spoke)" "$SUB_ID"
  ask_required DNS_SUB  "Subscription of the Private DNS zones" "$NET_SUB"
  ask_required MGMT_SUB "Subscription of Log Analytics / Sentinel" "$SUB_ID"

  ENC_HOST=true
  state=$(az feature show --subscription "$SUB_ID" --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv 2>/dev/null || echo Unknown)
  if [ "$state" != "Registered" ]; then
    warn "Encryption at host is '$state' on the workload subscription."
    ask_yn REG "Register it now (takes a few minutes)?" y
    if [ "$REG" = true ]; then
      az feature register --subscription "$SUB_ID" --namespace Microsoft.Compute --name EncryptionAtHost -o none
      info "Waiting for registration..."
      for _ in $(seq 1 40); do
        state=$(az feature show --subscription "$SUB_ID" --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv)
        [ "$state" = Registered ] && break
        sleep 15
      done
      az provider register --subscription "$SUB_ID" --namespace Microsoft.Compute -o none
      if [ "$state" = Registered ]; then
        ok "EncryptionAtHost registered"
      else
        warn "Still '$state' - disabling encryption at host for this deploy."; ENC_HOST=false
      fi
    else
      ENC_HOST=false
    fi
  fi

  # ------------------------------------------------------------------ network
  hdr "2/9 Network"
  pick VNET "Which VNet should the collectors join?" false < <(
    az network vnet list --subscription "$NET_SUB" --query "[].[name, resourceGroup, location, join(',', addressSpace.addressPrefixes)]" -o tsv)
  VNET_NAME=$(col "$VNET" 1); VNET_RG=$(col "$VNET" 2); LOCATION=$(col "$VNET" 3); VNET_SPACE=$(col "$VNET" 4)

  pick SUBNET "Which subnet?" false < <(
    az network vnet subnet list --subscription "$NET_SUB" -g "$VNET_RG" --vnet-name "$VNET_NAME" \
      --query "[?!contains(['GatewaySubnet','AzureBastionSubnet','AzureFirewallSubnet','AzureFirewallManagementSubnet','RouteServerSubnet'], name)].[name, addressPrefix || addressPrefixes[0]]" -o tsv)
  SUBNET_NAME=$(col "$SUBNET" 1); SUBNET_PREFIX=$(col "$SUBNET" 2)
  ok "Subnet $SUBNET_NAME ($SUBNET_PREFIX) in $VNET_NAME, region $LOCATION"

  # ------------------------------------------------------------------ naming
  hdr "3/9 Naming and tags"
  case "$LOCATION" in
    australiaeast) LS=aue ;; australiasoutheast) LS=ause ;; australiacentral) LS=auc ;;
    eastus) LS=eus ;; eastus2) LS=eus2 ;; westeurope) LS=weu ;; northeurope) LS=neu ;; uksouth) LS=uks ;;
    *) LS=$(printf '%s' "$LOCATION" | cut -c1-4) ;;
  esac
  while :; do
    ask ENVIRONMENT "Environment code (prd, nonprd, dev, tst)" "prd"
    [[ "$ENVIRONMENT" =~ ^[a-z0-9]{2,8}$ ]] && break
    warn "Use 2-8 lowercase letters/digits."
  done
  ask_required LOC_SHORT "Short region code used in names" "$LS"
  # shellcheck disable=SC2153  # assigned by ask_required via printf -v
  ask_required LZ_NAME   "LandingZone tag value" "platform-management"
  ask_required OWNER     "Owner tag (team or email)"
  ask_required COSTC     "CostCenter tag"

  # ------------------------------------------------------------------ access
  hdr "4/9 Admin access (Azure Bastion)"
  BASTION_NAME=""; BASTION_RG=""; BASTION_SUB=""; BASTION_CIDR=""
  pick BASTION "Which Azure Bastion will you use for SSH?" true < <(
    az network bastion list --subscription "$NET_SUB" --query "[].[name, resourceGroup, sku.name, ipConfigurations[0].subnet.id]" -o tsv 2>/dev/null || true)
  if [ -n "$BASTION" ]; then
    BASTION_NAME=$(col "$BASTION" 1); BASTION_RG=$(col "$BASTION" 2); BASTION_SUB=$NET_SUB
    BASTION_CIDR=$(az network vnet subnet show --ids "$(col "$BASTION" 4)" --query "addressPrefix || addressPrefixes[0]" -o tsv 2>/dev/null || true)
    [ "$(col "$BASTION" 3)" = "Basic" ] && warn "Bastion is Basic SKU: SSH works in the portal only (no 'az network bastion ssh')."
    [ -n "$BASTION_CIDR" ] && ok "AzureBastionSubnet is $BASTION_CIDR"
  else
    warn "No Bastion selected. SSH will only be allowed from the ranges you enter next."
  fi
  ask_cidr_list SSH_CIDRS "IP ranges allowed to SSH (normally only the AzureBastionSubnet)" "$BASTION_CIDR" false

  # ------------------------------------------------------------------ syslog sources
  hdr "5/9 Syslog senders"
  info "Only these ranges can send to UDP/TCP 514 and TLS 6514 (enforced by the NSG and the host firewall)."
  info "Include spokes, on-premises ranges over ExpressRoute/VPN and appliance subnets. Single IPs are fine."
  ask_cidr_list SYSLOG_CIDRS "Allowed syslog source ranges" "$VNET_SPACE" true

  # ------------------------------------------------------------------ HA + IPs
  hdr "6/9 Collectors and IP addresses"
  ask_int VM_COUNT "How many collector VMs" 2 1 5
  LB=false; [ "$VM_COUNT" -gt 1 ] && LB=true
  ask_yn LB "Front them with an internal load balancer (one IP/DNS name for senders)?" "$( [ "$LB" = true ] && echo y || echo n )"
  ask_yn STATIC "Assign static private IPs (recommended - senders are configured by IP)?" y
  VM_IPS=""; LB_IP=""; TAKEN=""
  if [ "$STATIC" = true ]; then
    info "Usable range: $SUBNET_PREFIX (Azure reserves the first 4 and the last address)."
    if [ "$LB" = true ]; then
      ask_ip_in_subnet LB_IP "Load balancer frontend IP" "$SUBNET_PREFIX" ""
      TAKEN=$LB_IP
    fi
    for i in $(seq 1 "$VM_COUNT"); do
      while :; do
        ask_ip_in_subnet ip "Collector $(printf '%02d' "$i") IP" "$SUBNET_PREFIX" "$TAKEN"
        [ -n "$ip" ] && break
        warn "Give every VM a static IP, or answer 'n' to static IPs to use dynamic ones."
      done
      VM_IPS="${VM_IPS:+$VM_IPS,}$ip"; TAKEN="${TAKEN:+$TAKEN,}$ip"
    done
  fi
  ask VM_SIZE "VM size" "Standard_D2as_v5"
  ZONES='["1", "2", "3"]'
  zones=$(az vm list-skus -l "$LOCATION" --size "$VM_SIZE" --subscription "$SUB_ID" --query "[0].locationInfo[0].zones" -o tsv 2>/dev/null | tr '\t' ' ' || true)
  if [ -z "$zones" ]; then
    warn "No Availability Zones reported for $VM_SIZE in $LOCATION - using an Availability Set."
    ZONES='[]'
  fi

  # ------------------------------------------------------------------ monitoring
  hdr "7/9 Log Analytics / Sentinel"
  pick LAW "Which Log Analytics workspace?" false < <(
    az monitor log-analytics workspace list --subscription "$MGMT_SUB" --query "[].[name, resourceGroup, location]" -o tsv)
  LAW_NAME=$(col "$LAW" 1); LAW_RG=$(col "$LAW" 2)

  # ------------------------------------------------------------------ DNS + TLS
  hdr "8/9 DNS and TLS"
  DNS_ZONE=""; DNS_RG=""
  pick ZONE "Private DNS zone for the 'syslog' A record" true < <(
    az network private-dns zone list --subscription "$DNS_SUB" --query "[?!starts_with(name, 'privatelink.')].[name, resourceGroup]" -o tsv 2>/dev/null || true)
  [ -n "$ZONE" ] && { DNS_ZONE=$(col "$ZONE" 1); DNS_RG=$(col "$ZONE" 2); }
  ask DNS_RECORD "A record name" "syslog"

  ask_yn TLS "Enable TLS syslog on 6514?" y
  TLS_SOURCE=selfsigned; KV_ID=""; KV_AUTH=rbac
  if [ "$TLS" = true ]; then
    pick KV "Key Vault holding the PEM certificate (0 = generate a self-signed one on each VM)" true < <(
      az keyvault list --subscription "$SUB_ID" --query "[].[name, resourceGroup, id, to_string(properties.enableRbacAuthorization)]" -o tsv 2>/dev/null || true)
    if [ -n "$KV" ]; then
      TLS_SOURCE=keyvault; KV_ID=$(col "$KV" 3)
      [ "$(col "$KV" 4)" = "true" ] || KV_AUTH=access_policy
      ask KV_CERT "Certificate name in that vault" "syslog-collector-tls"
    elif [ "$VM_COUNT" -gt 1 ]; then
      warn "Self-signed means each VM has its own certificate; Key Vault is better for $VM_COUNT VMs."
    fi
  fi

  # ------------------------------------------------------------------ retention
  hdr "9/9 Retention and options"
  ask_int LOCAL_DAYS "Days of logs on the VM's SSD" 7 1 90
  ask_yn ARCHIVE "Archive to private Blob Storage?" y
  BLOB_DAYS=30; SOFT_DAYS=7; BLOB_DNS=""
  if [ "$ARCHIVE" = true ]; then
    ask_int BLOB_DAYS "Days to keep logs in Blob Storage" 30 1 3650
    ask_int SOFT_DAYS "Blob soft-delete days (recovery window after deletion)" 7 1 365
    zone_id=$(az network private-dns zone list --subscription "$DNS_SUB" --query "[?name=='privatelink.blob.core.windows.net'].id | [0]" -o tsv 2>/dev/null || true)
    ask_yn POLICY_DNS "Does a Landing Zone policy create private endpoint DNS records automatically?" y
    if [ "$POLICY_DNS" = false ]; then
      if [ -n "$zone_id" ]; then BLOB_DNS=$zone_id; ok "Using $zone_id"
      else warn "privatelink.blob.core.windows.net not found in $DNS_SUB - the archive will not resolve until it exists."; fi
    fi
  fi
  ask_yn PRO "Upgrade the VMs to Ubuntu Pro (Livepatch, ESM; billed per VM hour)?" n

  # ------------------------------------------------------------------ write tfvars
  [ -f "$TFVARS" ] && cp "$TFVARS" "$TFVARS.bak.$(date +%Y%m%d%H%M%S)"
  {
    echo "# Generated by scripts/install.sh on $(date -u +%FT%TZ). Safe to edit and re-run."
    echo "subscription_id            = \"$SUB_ID\""
    echo "network_subscription_id    = \"$NET_SUB\""
    echo "dns_subscription_id        = \"$DNS_SUB\""
    echo "management_subscription_id = \"$MGMT_SUB\""
    echo
    echo "location          = \"$LOCATION\""
    echo "location_short    = \"$LOC_SHORT\""
    echo "environment       = \"$ENVIRONMENT\""
    # shellcheck disable=SC2153
    echo "landing_zone_name = \"$LZ_NAME\""
    echo "tags = {"
    echo "  Owner      = \"$OWNER\""
    echo "  CostCenter = \"$COSTC\""
    echo "}"
    echo
    echo "vnet_name                   = \"$VNET_NAME\""
    echo "vnet_resource_group_name    = \"$VNET_RG\""
    echo "subnet_name                 = \"$SUBNET_NAME\""
    echo "syslog_allowed_source_cidrs = $(hcl_list "$SYSLOG_CIDRS")"
    echo "ssh_allowed_source_cidrs    = $(hcl_list "$SSH_CIDRS")"
    echo "private_ip_addresses        = $(hcl_list "$VM_IPS")"
    echo
    echo "vm_count                      = $VM_COUNT"
    echo "vm_size                       = \"$VM_SIZE\""
    echo "zones                         = $ZONES"
    echo "enable_internal_load_balancer = $LB"
    echo "lb_private_ip_address         = $(hcl_str "$LB_IP")"
    echo "encryption_at_host_enabled    = $ENC_HOST"
    echo "ubuntu_pro                    = $PRO"
    echo
    echo "bastion_name                = $(hcl_str "$BASTION_NAME")"
    echo "bastion_resource_group_name = $(hcl_str "$BASTION_RG")"
    echo "bastion_subscription_id     = $(hcl_str "$BASTION_SUB")"
    echo
    echo "private_dns_zone_name                = $(hcl_str "$DNS_ZONE")"
    echo "private_dns_zone_resource_group_name = $(hcl_str "$DNS_RG")"
    echo "dns_record_name                      = \"$DNS_RECORD\""
    echo
    echo "enable_tls             = $TLS"
    echo "tls_certificate_source = \"$TLS_SOURCE\""
    echo "key_vault_id           = $(hcl_str "$KV_ID")"
    echo "key_vault_authorization = \"$KV_AUTH\""
    [ "$TLS_SOURCE" = keyvault ] && echo "tls_keyvault_certificate_name = \"$KV_CERT\""
    echo
    echo "log_analytics_workspace_name                = \"$LAW_NAME\""
    echo "log_analytics_workspace_resource_group_name = \"$LAW_RG\""
    echo
    echo "local_log_retention_days = $LOCAL_DAYS"
    echo "enable_blob_archive      = $ARCHIVE"
    echo "blob_retention_days      = $BLOB_DAYS"
    echo "archive_soft_delete_days = $SOFT_DAYS"
    echo "blob_private_dns_zone_id = $(hcl_str "$BLOB_DNS")"
  } > "$TFVARS"
  terraform fmt "$TFVARS" >/dev/null
  ok "Wrote $TFVARS"
fi

# ------------------------------------------------------------------ remote state
hdr "Terraform state"
if [ -f "$BACKEND" ]; then
  ask_yn REUSE_BE "terraform/backend.hcl exists. Reuse it?" y
else
  REUSE_BE=false
fi
if [ "$REUSE_BE" = false ]; then
  sub_default=$(grep -E '^management_subscription_id' "$TFVARS" | cut -d'"' -f2 || true)
  env_default=$(grep -E '^environment' "$TFVARS" | cut -d'"' -f2 || true)
  ask_required ST_SUB "State storage subscription" "${sub_default:-$CUR_SUB}"
  ask_required ST_RG  "State storage resource group" "rg-tfstate-${env_default:-prd}-001"
  ask_required ST_ACC "State storage account name"
  ask_required ST_CON "State container" "tfstate"
  ask_required ST_KEY "State blob key" "shared-services/syslog/${env_default:-prd}.tfstate"
  if ! az storage account show --subscription "$ST_SUB" -g "$ST_RG" -n "$ST_ACC" -o none 2>/dev/null; then
    ask_yn MAKE_ST "Storage account $ST_ACC does not exist. Create it (Entra ID only, versioning, soft delete)?" y
    [ "$MAKE_ST" = true ] || die "Create the state storage account first, then re-run."
    loc=$(grep -E '^location ' "$TFVARS" | cut -d'"' -f2 || echo australiaeast)
    "$SCRIPTS_DIR/bootstrap-state.sh" "$ST_SUB" "$ST_RG" "$ST_ACC" "$loc"
  fi
  cat > "$BACKEND" <<EOF
subscription_id      = "$ST_SUB"
resource_group_name  = "$ST_RG"
storage_account_name = "$ST_ACC"
container_name       = "$ST_CON"
key                  = "$ST_KEY"
use_azuread_auth     = true
EOF
  ok "Wrote $BACKEND"
fi

# ------------------------------------------------------------------ SSH key
hdr "Admin SSH key"
if [ ! -f "$SSH_KEY" ]; then
  mkdir -p "$(dirname "$SSH_KEY")" && chmod 700 "$(dirname "$SSH_KEY")"
  ssh-keygen -q -t rsa -b 4096 -f "$SSH_KEY" -N "" -C "syslog-lz-admin"
  ok "Created $SSH_KEY (keep it; it is the break-glass login)"
else
  ok "Using existing $SSH_KEY"
fi
TF_VAR_admin_ssh_public_key="$(cat "$SSH_KEY.pub")"
export TF_VAR_admin_ssh_public_key

# ------------------------------------------------------------------ review
hdr "Review"
grep -vE '^\s*#' "$TFVARS" | sed '/^\s*$/d'
echo
ask_yn GO "Run terraform init + plan with these settings?" y
[ "$GO" = true ] || { info "Stopped. Edit $TFVARS and re-run."; exit 0; }

# ------------------------------------------------------------------ terraform
hdr "terraform init"
tf init -input=false -reconfigure -backend-config=backend.hcl
tf validate

hdr "terraform plan"
tf plan -input=false -out tfplan
if [ "$PLAN_ONLY" = true ]; then
  ok "Plan saved to terraform/tfplan. Apply later with: terraform -chdir=terraform apply tfplan"
  exit 0
fi

read -r -u 3 -p "${C_B}Type 'apply' to create these resources:${C_0} " confirm
[ "$confirm" = apply ] || { info "Not applied. The plan is saved in terraform/tfplan."; exit 0; }

hdr "terraform apply (10-20 minutes; keep this tab active)"
tf apply -input=false tfplan
rm -f "$TF_DIR/tfplan"

hdr "Done"
tf output syslog_endpoint_ip
tf output syslog_dns_name
tf output collector_private_ips
ask_yn VAL "Run the post-deployment checks now (scripts/validate.sh)?" y
[ "$VAL" = true ] && "$SCRIPTS_DIR/validate.sh"
ok "Point your syslog senders at the endpoint above. Uninstall with: ./scripts/uninstall.sh"
