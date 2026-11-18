#!/usr/bin/env bash
# Interactive uninstaller for the azure-syslog collector. Run in Azure Cloud Shell (bash):
#
#   ./scripts/uninstall.sh
#
# Destroys what install.sh / terraform created. Existing Landing Zone resources
# (VNet, DNS zones, workspace, Key Vault, Bastion) are never touched. You can
# keep the Blob Storage log archive, and you must type the resource group name
# to confirm.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "${1:-}" in -h|--help) sed -n '2,9p' "$0"; exit 0 ;; "") ;; *) die "Unknown option: $1" ;; esac

hdr "Preflight"
require_tools az terraform python3 ssh-keygen
require_login
[ -f "$TFVARS" ]  || die "terraform/terraform.tfvars not found - nothing to uninstall from this checkout."
[ -f "$BACKEND" ] || die "terraform/backend.hcl not found - recreate it so Terraform can find the state (see backend.hcl.example)."

# Destroy still needs a value for this variable; any key will do.
if [ -f "$SSH_KEY.pub" ]; then
  TF_VAR_admin_ssh_public_key="$(cat "$SSH_KEY.pub")"
else
  tmpkey="$(mktemp -d)/k"
  ssh-keygen -q -t rsa -b 2048 -f "$tmpkey" -N ""
  TF_VAR_admin_ssh_public_key="$(cat "$tmpkey.pub")"
  rm -rf "$(dirname "$tmpkey")"
fi
export TF_VAR_admin_ssh_public_key

tf init -input=false -reconfigure -backend-config=backend.hcl >/dev/null
STATE=()
while IFS= read -r line; do [ -n "$line" ] && STATE+=("$line"); done < <(tf state list 2>/dev/null || true)
[ "${#STATE[@]}" -gt 0 ] || die "The Terraform state is empty - nothing is deployed with this configuration."

RG=$(tf output -raw resource_group_name 2>/dev/null || true)
[ -n "$RG" ] || die "Could not read resource_group_name from the state."
ok "Found ${#STATE[@]} resources in resource group $RG"
tf output collector_private_ips 2>/dev/null || true

# ------------------------------------------------------------------ archive
in_state() { printf '%s\n' "${STATE[@]}" | grep -qxF "$1"; }
KEEP_ARCHIVE=false
ARCH=""
if in_state 'azurerm_storage_account.archive[0]'; then
  ARCH=$(tf output -json archive_storage_account 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin) or {}; print(d.get("name",""))' 2>/dev/null || true)
  hdr "Log archive"
  info "Blob Storage account ${ARCH:-<archive>} holds up to the last $(grep -E '^blob_retention_days' "$TFVARS" | grep -oE '[0-9]+' || echo 30) days of logs."
  ask_yn KEEP_ARCHIVE "Keep the archive (recommended if the logs may be needed as evidence)?" y
fi

# ------------------------------------------------------------------ confirm
hdr "Confirm"
if [ "$KEEP_ARCHIVE" = true ]; then
  info "Will DELETE the collectors, disks, NICs, NSG, ASG, load balancer, DCR, DNS records and role assignments."
  info "Will KEEP the archive storage account, its container, lifecycle policy and private endpoint (and the resource group)."
else
  warn "Will DELETE everything this deployment created, INCLUDING the archive storage account and every archived log."
fi
info "Local logs on the collectors' disks are deleted with the disks."
read -r -u 3 -p "${C_B}Type the resource group name ($RG) to continue:${C_0} " typed
[ "$typed" = "$RG" ] || die "Name did not match - nothing was changed."

# ------------------------------------------------------------------ keep: detach from state
if [ "$KEEP_ARCHIVE" = true ]; then
  KEEP=(
    'azurerm_storage_account.archive[0]'
    'azurerm_storage_container.archive[0]'
    'azurerm_storage_management_policy.archive[0]'
    'azurerm_storage_container_immutability_policy.archive[0]'
    'azurerm_private_endpoint.archive_blob[0]'
    'azurerm_monitor_diagnostic_setting.archive_blob[0]'
    'random_string.archive_suffix[0]'
  )
  # A resource group created here cannot be deleted while it still holds the archive.
  in_state 'azurerm_resource_group.this[0]' && KEEP+=('azurerm_resource_group.this[0]')
  for addr in "${KEEP[@]}"; do
    if in_state "$addr"; then
      tf state rm "$addr" >/dev/null && info "  kept (removed from state): $addr"
    fi
  done
fi

# ------------------------------------------------------------------ destroy
hdr "terraform plan -destroy"
tf plan -destroy -input=false -out destroy.tfplan
read -r -u 3 -p "${C_B}Type 'destroy' to delete these resources:${C_0} " confirm
if [ "$confirm" != destroy ]; then
  rm -f "$TF_DIR/destroy.tfplan"
  [ "$KEEP_ARCHIVE" = true ] && warn "The archive resources were already detached from state; they still exist in Azure."
  die "Cancelled - nothing was deleted."
fi
tf apply -input=false destroy.tfplan
rm -f "$TF_DIR/destroy.tfplan"
ok "Collector deployment removed."

[ "$KEEP_ARCHIVE" = true ] && info "Archive kept in resource group $RG${ARCH:+ (account $ARCH)}. Blobs keep expiring per the lifecycle policy; delete the account in the portal when no longer needed."
info "A Key Vault certificate created by Terraform is soft-deleted, not purged. Data already in Log Analytics stays until workspace retention removes it."

# ------------------------------------------------------------------ local cleanup
hdr "Local files"
ask_yn CLEAN "Delete local terraform.tfvars and backend.hcl?" n
if [ "$CLEAN" = true ]; then rm -f "$TFVARS" "$BACKEND"; ok "Removed local configuration"; fi
if [ -f "$SSH_KEY" ]; then
  ask_yn RMKEY "Delete the admin SSH key $SSH_KEY?" n
  if [ "$RMKEY" = true ]; then rm -f "$SSH_KEY" "$SSH_KEY.pub"; ok "Removed SSH key"; fi
fi
ok "Uninstall complete."
