#!/usr/bin/env bash
# Post-deployment checks from Cloud Shell - no network path to the VMs needed.
# Uses 'az vm run-command' (control plane) on every collector:
#   listeners, firewall, service health, and a UDP + TCP loop-back test.
# Run from the terraform/ directory after 'terraform apply'.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../terraform"

read -r -d '' REMOTE <<'SH' || true
set -u
echo "--- rsyslog";   systemctl is-active rsyslog; rsyslogd -N1 2>&1 | tail -n 2
echo "--- listeners"; ss -Hlntup | grep -E ':(514|6514)\b' || echo "NO LISTENERS"
echo "--- ufw";       ufw status | head -n 20
echo "--- log disk";  findmnt /var/log/remote || echo "not a separate mount"
IP="$(hostname -I | awk '{print $1}')"
TAG="lz-syslog-selftest-$(date +%s)"
logger --server "$IP" --port 514 --udp "$TAG udp"
logger --server "$IP" --port 514 --tcp "$TAG tcp"
sleep 3
echo "--- received";  grep -rh "$TAG" /var/log/remote/ || echo "TEST MESSAGES NOT FOUND"
echo "--- tls";       timeout 5 openssl s_client -connect 127.0.0.1:6514 -brief </dev/null 2>&1 | head -n 4 || true
echo "--- ama";       systemctl is-active azuremonitoragent 2>/dev/null || echo "AMA not installed"
ls /etc/rsyslog.d/
SH

terraform output -json collector_vm_ids | python3 -c 'import json,sys; [print(n, i) for n, i in json.load(sys.stdin).items()]' |
while read -r name id; do
  echo "================ $name"
  az vm run-command invoke --ids "$id" --command-id RunShellScript \
    --scripts "$REMOTE" --query 'value[0].message' -o tsv
done

cat <<'KQL'

Log Analytics / Sentinel (allow 5-10 minutes for first ingestion):
  Syslog
  | where TimeGenerated > ago(30m)
  | where SyslogMessage has "lz-syslog-selftest"
  | project TimeGenerated, HostName, HostIP, Facility, SeverityLevel, SyslogMessage
KQL
