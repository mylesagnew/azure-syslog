# azure-syslog

A hardened central syslog collector (rsyslog on Ubuntu 24.04 LTS) for an existing
CAF-aligned Azure Landing Zone. **Terraform** builds the infrastructure,
**Ansible** hardens the OS and configures rsyslog. You run all of it from
**Azure Cloud Shell (bash)**.

- Listens on **UDP/514**, **TCP/514** and **TLS/6514** (RFC 5425)
- **Private only.** No public IP. Admin access goes through **Azure Bastion**
- **Zone-redundant**: 1 to 5 VMs spread across Availability Zones, with an optional internal Standard Load Balancer and one DNS name
- Writes one log file per sender to an encrypted data disk, and forwards to **Log Analytics / Microsoft Sentinel** through the Azure Monitor Agent (AMA) and a Data Collection Rule
- No secrets in code, state or extension payloads. The TLS certificate comes from **Key Vault** through the VM's **managed identity**

---

## Architecture

```
            On-prem (ER/VPN)        Spoke VNets            NVAs / firewalls
                   │                     │                        │
                   └──────── UDP/TCP 514, TLS 6514 (allowed CIDRs only) ───────┐
                                                                               ▼
┌──────────────────────────── Hub / shared-services VNet ─────────────────────────────┐
│                                                                                     │
│   Private DNS: syslog.internal.contoso.com ──► Internal Standard LB (zone-redundant)│
│                                                  │ health probe TCP/514             │
│                         ┌────────────────────────┼────────────────────────┐         │
│                         ▼                        ▼                        ▼         │
│                 vm-syslog-prd-aue-01     vm-syslog-prd-aue-02     (zone 3 ...)      │
│                 zone 1                   zone 2                                     │
│                 ├ NIC NSG + ASG (least privilege)                                   │
│                 ├ ufw (same allow-list), SSH hardened, auditd, unattended-upgrades  │
│                 ├ rsyslog ruleset "remote" ──► /var/log/remote/<sender-ip>/ (disk)  │
│                 │                          └─► AMA (127.0.0.1) ─┐                   │
│                 └ System-assigned MI ──► Key Vault (private endpoint): TLS cert     │
│                                                                 │                   │
│   AzureBastionSubnet ──SSH 22──► collectors (only SSH source)   │                   │
└─────────────────────────────────────────────────────────────────┼───────────────────┘
                                                                  ▼
                      DCR (Microsoft-Syslog / Microsoft-CommonSecurityLog)
                                                                  ▼
                 Log Analytics workspace (management subscription) + Microsoft Sentinel
                 ▲ NSG logs + VM/NIC/LB metrics through diagnostic settings
```

### How it fits the Landing Zone

| LZ resource | Where it lives | How this repo uses it |
|---|---|---|
| VNet / subnet | connectivity or management spoke (`network_subscription_id`) | `data.azurerm_subnet`. The subnet NSG and UDR stay owned by the platform team |
| Private DNS zone | connectivity (`dns_subscription_id`) | A records for the endpoint and for each VM |
| Log Analytics / Sentinel | management (`management_subscription_id`) | DCR destination and diagnostic settings |
| Key Vault | shared services / identity | MI gets **Key Vault Secrets User** on the single certificate secret |
| Azure Bastion | hub | Only SSH source, for `az network bastion ssh` and `tunnel` |
| Hub firewall | hub | Egress for apt and AMA. Use the ASG output in your rules |

Each existing resource is read through a provider alias (`network`, `dns`,
`management`). An alias left `null` falls back to the workload subscription.

### Repository layout

```
terraform/
  versions.tf providers.tf backend.tf    providers (azurerm 4.x, archive, null), 4 subscription aliases
  variables.tf terraform.tfvars.example  all inputs, with validation
  locals.tf data.tf main.tf              naming/tags, existing LZ lookups, RG + cross-variable guards
  network.tf                             ASG, NIC NSG + rules, NICs, optional PIP, optional internal LB
  compute.tf                             VMs, log disks, AMA / Entra SSH / Ansible extensions
  monitoring.tf                          DCR + association, diagnostic settings
  keyvault.tf dns.tf outputs.tf
  templates/cloud-init.yaml              first boot: pre-installs ansible, rsyslog, ufw
  templates/bootstrap.sh.tftpl           CSE script: unpack the embedded playbook and run it locally
ansible/
  site.yml  ansible.cfg  inventory/local.yml  requirements.yml  group_vars/
  roles/baseline_hardening/              CIS-inspired OS baseline
  roles/rsyslog_collector/               disk, TLS, AppArmor, rsyslog, logrotate, ufw
scripts/
  validate.sh                            post-deploy checks through az vm run-command
  test-syslog-client.sh                  send test messages from a source host
  ansible-push-via-bastion.sh            alternative Ansible delivery over a Bastion tunnel
  bootstrap-state.sh                     optional Terraform state storage
```

The Terraform root is split by concern rather than into child modules. It is
one deployable unit, and a flat root keeps the Landing Zone wiring easy to see.
Each file maps cleanly onto a future `modules/<name>` if you want to reuse it.

---

## How Ansible is invoked

| `ansible_mode` | Path | When to use |
|---|---|---|
| **`cse`** (default) | Terraform zips `ansible/` and embeds it in a script passed through the **Custom Script Extension** protected settings (encrypted). The VM runs `ansible-playbook -c local` against itself. | Private subnets. Cloud Shell has no network path to the VM, so this is the right choice for a standard Landing Zone. |
| `bastion_push` | `null_resource` with `local-exec` runs `scripts/ansible-push-via-bastion.sh`, which opens `az network bastion tunnel` per VM and runs Ansible from Cloud Shell. | You want classic push Ansible. Needs Bastion **Standard or Premium** with native client support. |
| `none` | Infrastructure only. | You run Ansible from your own pipeline: `terraform output -json ansible_extra_vars > ansible/terraform-vars.json`. |

Both modes are idempotent. In `cse` mode, a change to any file under `ansible/`,
or to any Ansible input, re-runs the extension on the next `terraform apply`.
An optional weekly systemd timer (`ansible_reconverge_weekly`) re-applies the
same revision to correct drift.

---

## Prerequisites

1. **Permissions** for the Cloud Shell identity, scoped as tightly as possible:
   - *Contributor* on the target resource group (or on the subscription, if the RG is created)
   - *Network Contributor*, or a custom role with `Microsoft.Network/virtualNetworks/subnets/join/action`, on the subnet
   - *Private DNS Zone Contributor* on the zone
   - *Monitoring Contributor* on the RG, and *Log Analytics Reader* on the workspace
   - *Role Based Access Control Administrator*, constrained to *Key Vault Secrets User* and *Virtual Machine Administrator Login*, for the role assignments
   - *Storage Blob Data Contributor* on the state container
2. **Encryption at host** registered once per subscription:
   ```bash
   az feature register --namespace Microsoft.Compute --name EncryptionAtHost
   az provider register -n Microsoft.Compute
   ```
3. **Egress** from the subnet, through the hub firewall, to:
   - the Ubuntu mirrors (`azure.archive.ubuntu.com`, `security.ubuntu.com`)
   - the AMA endpoints (`global.handler.control.monitor.azure.com`, `<region>.handler.control.monitor.azure.com`, `<workspace-id>.ods.opinsights.azure.com`), or an AMPLS
   - the Key Vault private endpoint
4. **Key Vault certificate** (when `tls_certificate_source = "keyvault"`). The secret's content type must be **`application/x-pem-file`**. Either:
   - issue or import it yourself (recommended, from your enterprise CA), or
   - set `tls_keyvault_generate_certificate = true`. This calls the vault's data plane from Cloud Shell, so the vault firewall must allow Cloud Shell, or Cloud Shell must run in a VNet.
5. **Bastion**: Standard or Premium with *Native client support*, for `az network bastion ssh` and `tunnel`. Basic SKU works through the portal only.

---

## Variables (key ones)

| Variable | Purpose |
|---|---|
| `subscription_id`, `network_/dns_/management_subscription_id` | Where each LZ component lives |
| `vnet_name`, `vnet_resource_group_name`, `subnet_name` | Existing subnet for the NICs and LB |
| `syslog_allowed_source_cidrs` | **Only** these ranges may send syslog. Applied to both the NSG and ufw. `0.0.0.0/0` is rejected |
| `ssh_allowed_source_cidrs` | AzureBastionSubnet prefix |
| `vm_count`, `zones`, `enable_internal_load_balancer` | High availability. An empty `zones` list creates an Availability Set |
| `vm_size` | Default `Standard_D2as_v5` (see the cost notes) |
| `data_disk_size_gb` | Dedicated log disk mounted at `/var/log/remote` (`0` = OS disk) |
| `encryption_at_host_enabled`, `disk_encryption_set_id` | Disk encryption (host encryption, plus an optional customer-managed key) |
| `enable_tls`, `tls_certificate_source`, `tls_auth_mode`, `key_vault_id` | TLS on 6514 |
| `log_analytics_workspace_name`, `enable_ama`, `enable_dcr`, `dcr_syslog_facilities`, `dcr_syslog_log_levels`, `dcr_cef_facilities` | Sentinel and Log Analytics ingestion |
| `remote_log_format`, `remote_log_retention_days`, `rsyslog_forward_targets` | rsyslog behaviour |
| `ansible_mode` | `cse`, `bastion_push` or `none` |
| `tags` | Must include `Owner` and `CostCenter`. Merged over the standard Environment, Workload, LandingZone, DataClassification, Criticality and ManagedBy tags |

`variables.tf` documents every variable. Each Ansible role's `defaults/main.yml` documents the rsyslog and hardening tunables.

---

## Deploy from Azure Cloud Shell (bash)

```bash
# 0. Get the code (Cloud Shell persists $HOME on your clouddrive)
git clone https://github.com/mylesagnew/azure-syslog.git
cd azure-syslog/terraform
```

```bash
# 1. Authentication. Cloud Shell is already signed in as you; pick the workload subscription.
az account show -o table
az account set --subscription "<workload-subscription-id>"
```

To run as a service principal instead (for example, to match pipeline permissions):
```bash
export ARM_CLIENT_ID=... ARM_TENANT_ID=... ARM_SUBSCRIPTION_ID=... ARM_CLIENT_SECRET=...   # or use OIDC/MI in CI
```

```bash
# 2. Admin SSH key (public half goes to the VM; private stays in Cloud Shell)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/syslog_admin -N "" -C "syslog-lz-admin"
export TF_VAR_admin_ssh_public_key="$(cat ~/.ssh/syslog_admin.pub)"
```

```bash
# 3. Configuration
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
code terraform.tfvars     # Cloud Shell editor - set subscriptions, VNet, CIDRs, workspace, Key Vault ...
```

```bash
# 4. Init / plan / apply
terraform init -backend-config=backend.hcl
terraform fmt -check && terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

```bash
# 5. Outputs: private IPs, DNS name, Bastion SSH commands, test commands
terraform output
```

```bash
# 6. Validate (runs on the VMs through the control plane - no network path needed)
../scripts/validate.sh
```

Expect `terraform apply` to take about 10 to 20 minutes. Most of that is the Custom Script Extension
running apt and Ansible. If the extension fails, Terraform shows the error, and
the full log is in `/var/log/syslog-lz-bootstrap.log` on the VM.

---

## Post-deployment validation

1. **Listeners and loopback test**: `../scripts/validate.sh`. It shows rsyslog status, the
   514/6514 listeners, ufw rules, the log mount, and confirms that a UDP and a TCP test message
   arrived under `/var/log/remote/`.
2. **From a real source** inside `syslog_allowed_source_cidrs`:
   ```bash
   logger --server syslog.internal.contoso.com --port 514 --udp "lz-syslog-test udp"
   logger --server syslog.internal.contoso.com --port 514 --tcp "lz-syslog-test tcp"
   echo "<134>lz-syslog-test nc" | nc -u -w1 syslog.internal.contoso.com 514
   openssl s_client -connect syslog.internal.contoso.com:6514 -brief </dev/null   # TLS handshake
   ```
   Or copy `scripts/test-syslog-client.sh` to the source host and run it.
3. **On the collector** (Bastion SSH; the command is in `terraform output bastion_ssh_commands`):
   ```bash
   sudo ls /var/log/remote/
   sudo tail -f /var/log/remote/<sender-ip>/syslog.log
   sudo ss -lntup | grep -E ':(514|6514)'
   ```
4. **Log Analytics / Sentinel**. Allow 5 to 10 minutes for the first records:
   ```kusto
   Syslog
   | where TimeGenerated > ago(30m)
   | where SyslogMessage has "lz-syslog-test"
   | project TimeGenerated, HostName, HostIP, Facility, SeverityLevel, SyslogMessage
   ```
   Test messages use facility `user` at level `notice`. The default `dcr_syslog_log_levels`
   drops Debug and Info, so a message at those levels will not appear in Log Analytics,
   although it is still written to disk.
5. **AMA path**: on the VM, `ls /etc/rsyslog.d/10-azuremonitoragent*` and
   `sudo ss -lntp | grep 28330`. Ansible reads AMA's port from that file. If AMA had not yet
   received the DCR on the first run, re-run `terraform apply` or wait for the weekly converge timer.

---

## Microsoft Sentinel integration

- The DCR created here is the same object the Sentinel **"Syslog via AMA"** connector creates.
  Install the *Syslog* solution from the Content Hub to get the workbooks and analytics rules. The
  connector page will list this DCR.
- For appliances that send **CEF** (firewalls, proxies), point them at a dedicated facility
  (for example `local4`) and set `dcr_cef_facilities = ["local4"]`. Records then land in
  `CommonSecurityLog` (*"Common Event Format (CEF) via AMA"* solution). Keep CEF facilities out of
  `dcr_syslog_facilities`; Terraform enforces this to avoid double ingestion.
- Remote events are forwarded to AMA from the `remote` ruleset only, so the collector's own OS
  logs are not mixed in. AMA's default ruleset hook still ships the collector's local logs that
  match the DCR.

---

## Security baseline (Microsoft Cloud Security Benchmark mapping)

| Control | Implementation |
|---|---|
| NS-1/NS-2: segmentation, private access | No public IP. NIC NSG allows syslog only from the listed CIDRs to the ASG, and SSH only from Bastion; explicit deny at priority 4000. ufw mirrors the same allow-list |
| PA/IM: identity | SSH keys only (passwords disabled), optional Entra ID SSH login, system-assigned MI for Key Vault and AMA |
| DP-4/DP-5: encryption at rest | Encryption at host, optional Disk Encryption Set (customer-managed key), managed disks with `DenyAll` network access |
| DP-3: encryption in transit | TLS 6514. Key Vault and AMA traffic over TLS |
| DP-6/DP-7: keys and certificates | Certificate in Key Vault, RBAC on the single secret, auto-renew policy, no secret in Terraform state or CSE payload |
| PV: posture and vulnerability | Trusted Launch (Secure Boot + vTPM), unattended security upgrades, needrestart, Update Manager assessment, CIS-inspired sysctl, modprobe, sshd, auditd and core-dump settings |
| LT-3/LT-4: logging | AMA + DCR to the workspace, NSG logs and platform metrics through diagnostic settings, auditd rules on identity, sudo and syslog config, persistent journal |

Recommended platform add-ons: Defender for Servers Plan 2 on the subscription, Azure Policy
guest configuration (Linux baseline), and VNet flow logs at VNet scope (these replace NSG flow logs).

---

## Operations

- **Change configuration**: edit `ansible/` or `terraform.tfvars`, then `terraform apply`. The CSE re-runs.
- **Certificate renewal** (Key Vault auto-renews 30 days before expiry): the weekly converge timer
  fetches the new version and restarts rsyslog. To pick it up immediately, run
  `sudo systemctl start syslog-lz-converge.service`.
- **Scale out**: increase `vm_count`, with `enable_internal_load_balancer = true`. TCP senders keep
  their session on one backend, and UDP is distributed per flow.
- **Disk usage**: logrotate runs daily with `maxsize 1G`. For very noisy senders, run logrotate hourly
  or increase `data_disk_size_gb`. `/var/log/rsyslog-stats.log` shows queue pressure.
- **Self-signed TLS with more than one VM**: each VM generates its own certificate, so clients must
  trust each one or use `anon` mode. Use Key Vault for multi-VM TLS.

---

## Cost notes (pay-as-you-go, indicative only - check the pricing calculator for your region)

| Item | Recommendation |
|---|---|
| VM | **Standard_D2as_v5** (2 vCPU / 8 GiB) handles thousands of events per second and sustains load without CPU credits. **B2s_v2** is cheaper for labs or low, bursty volumes, but throttles once credits run out. Reserved instances or a savings plan cut the cost by about 40 to 60% for a 24x7 collector. |
| Disks | 64 GiB Premium OS + 128 GiB Premium data per VM. Standard SSD halves the disk cost and is fine below about 500 events per second. |
| Internal LB | Standard LB rule and data-processed charges (small) |
| **Log Analytics ingestion** | Usually the **largest** cost, billed per GB. Control it with `dcr_syslog_log_levels` and `dcr_syslog_facilities`, a commitment tier, or by keeping verbose data on disk only. |

---

## Cleanup / destroy

```bash
cd azure-syslog/terraform
terraform plan -destroy -out destroy.tfplan
terraform apply destroy.tfplan
```

- This removes the VMs, disks, NICs, NSG, ASG, LB, DCR, DNS records, role assignments and access
  policies. It never deletes the existing VNet, DNS zone, workspace, Key Vault or Bastion.
- A generated Key Vault certificate is soft-deleted, not purged (`purge_soft_delete_on_destroy = false`).
- Data already ingested into Log Analytics stays until the workspace retention removes it.
- If you used `create_resource_group = false`, the shared RG is kept.
- Optionally remove the local key: `rm ~/.ssh/syslog_admin*`.
