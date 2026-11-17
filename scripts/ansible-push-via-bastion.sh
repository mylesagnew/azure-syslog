#!/usr/bin/env bash
# Run the Ansible playbook from Cloud Shell against private collectors through
# Azure Bastion native-client tunnels (Bastion Standard/Premium, "Native client
# support" enabled). Called by Terraform (ansible_mode = "bastion_push") or by hand.
#
# Required env: BASTION_NAME BASTION_RESOURCE_GROUP VM_IDS (comma-separated)
#               ADMIN_USERNAME SSH_PRIVATE_KEY EXTRA_VARS_JSON
# Optional env: BASTION_SUBSCRIPTION_ID LOCAL_PORT (default 50022)
set -euo pipefail

: "${BASTION_NAME:?}" "${BASTION_RESOURCE_GROUP:?}" "${VM_IDS:?}"
: "${ADMIN_USERNAME:?}" "${SSH_PRIVATE_KEY:?}" "${EXTRA_VARS_JSON:?}"
LOCAL_PORT="${LOCAL_PORT:-50022}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$HERE/../ansible"
WORK="$(mktemp -d)"
TUNNEL_PID=""

cleanup() {
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

printf '%s' "$EXTRA_VARS_JSON" > "$WORK/terraform-vars.json"

# Cloud Shell: install Ansible into the user's home (persisted on the clouddrive).
if ! command -v ansible-playbook >/dev/null 2>&1; then
  python3 -m pip install --user --quiet 'ansible-core>=2.19'  # 26.04 ships a newer Python than older cores support
  export PATH="$HOME/.local/bin:$PATH"
fi
ansible-galaxy collection install -r "$ANSIBLE_DIR/requirements.yml" >/dev/null

SUB_ARGS=()
[ -n "${BASTION_SUBSCRIPTION_ID:-}" ] && SUB_ARGS=(--subscription "$BASTION_SUBSCRIPTION_ID")

IFS=',' read -r -a vms <<< "$VM_IDS"
for vm_id in "${vms[@]}"; do
  vm_name="${vm_id##*/}"
  echo "==> $vm_name: opening Bastion tunnel on 127.0.0.1:$LOCAL_PORT"
  az network bastion tunnel \
    --name "$BASTION_NAME" --resource-group "$BASTION_RESOURCE_GROUP" "${SUB_ARGS[@]}" \
    --target-resource-id "$vm_id" --resource-port 22 --port "$LOCAL_PORT" \
    >"$WORK/tunnel-$vm_name.log" 2>&1 &
  TUNNEL_PID=$!

  for _ in $(seq 1 30); do
    if (echo >"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; then break; fi
    sleep 2
  done

  cat > "$WORK/inventory.yml" <<INV
all:
  children:
    syslog_collectors:
      hosts:
        $vm_name:
          ansible_host: 127.0.0.1
          ansible_port: $LOCAL_PORT
          ansible_user: $ADMIN_USERNAME
          ansible_ssh_private_key_file: $SSH_PRIVATE_KEY
          # Same local port for every VM: pin host keys per VM name.
          ansible_ssh_common_args: >-
            -o HostKeyAlias=$vm_name
            -o StrictHostKeyChecking=accept-new
            -o UserKnownHostsFile=$HOME/.ssh/known_hosts_syslog_lz
INV

  echo "==> $vm_name: running playbook"
  ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
    -i "$WORK/inventory.yml" "$ANSIBLE_DIR/site.yml" -e "@$WORK/terraform-vars.json"

  kill "$TUNNEL_PID" 2>/dev/null || true
  wait "$TUNNEL_PID" 2>/dev/null || true
  TUNNEL_PID=""
done
