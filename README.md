# azure-syslog

A hardened central syslog collector (rsyslog on **Ubuntu 26.04.1 LTS**) for an existing
CAF-aligned Azure Landing Zone. **Terraform** builds the infrastructure,
**Ansible** hardens the OS and configures rsyslog. You run all of it from
**Azure Cloud Shell (bash)**.

- Listens on **UDP/514**, **TCP/514** and **TLS/6514** (RFC 5425)
- **Private only.** No public IP. Admin access goes through **Azure Bastion**
- **Zone-redundant**: 1 to 5 VMs spread across Availability Zones, with an optional internal Standard Load Balancer and one DNS name
- Writes one log file per sender to an encrypted data disk, and forwards to **Log Analytics / Microsoft Sentinel** through the Azure Monitor Agent (AMA) and a Data Collection Rule
- No secrets in code, state or extension payloads. The TLS certificate comes from **Key Vault** through the VM's **managed identity**

**New here? Follow the [step-by-step deployment guide](#step-by-step-deployment-guide-azure-cloud-shell).**

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

## Operating system: Ubuntu 26.04.1 LTS

- **Image:** `Canonical:ubuntu-26_04-lts:server:latest`, the free *Ubuntu Server 26.04 LTS* plan (AMD64, Gen2, Trusted Launch capable) of Canonical's [unified 26.04 offer](https://marketplace.microsoft.com/en-us/product/canonical.ubuntu-26_04-lts). `latest` always resolves to the newest 26.04 build, which is 26.04.1 or later.
- **Ubuntu Pro (optional):** the same offer includes the *Ubuntu Pro Server* plan: set `source_image.sku = "pro-server"`. It adds Kernel Livepatch, up to 15 years of security maintenance, and certified CIS/STIG hardening tooling, billed per VM hour. The separate *Ubuntu Pro 26.04 LTS* offer exists only for other procurement options. Check the exact SKU in your region first:
  ```bash
  az vm image list-skus -l australiaeast -p Canonical -f ubuntu-26_04-lts -o table
  ```
- **Enforced point release:** before changing anything, the playbook reads `VERSION` from `/etc/os-release` and stops unless the host is Ubuntu 26.04 at `required_ubuntu_release` (default `26.04.1`) or later. Raise the variable (for example to `26.04.2`) to require a newer point release.
- **SSH:** OpenSSH 10.x offers the hybrid post-quantum `mlkem768x25519-sha256` key exchange, so it is listed first.
- **Ansible from Cloud Shell** (`bastion_push`) needs `ansible-core` 2.19 or later, because 26.04 ships a newer Python than older releases support. The script installs it when missing.

> **Check before production:** at the time of writing, Microsoft's [Azure Monitor Agent supported OS list](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-supported-operating-systems) did not yet name Ubuntu 26.04. AMA 1.45 (September 2026) only taught its troubleshooter to recognise 26.04. Confirm 26.04 support on that page, and for `AADSSHLoginForLinux` if you use Entra SSH login. If AMA is not supported yet, deploy with `enable_ama = false` and forward to Sentinel from an existing supported collector using `rsyslog_forward_targets`.

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

## Step-by-step deployment guide (Azure Cloud Shell)

Do the steps in order. Each step says **what** to do, **why**, and **how to check it worked**.
Replace placeholder values (`<...>`, `contoso`, example IDs) with your own.

### Step 1: Open Azure Cloud Shell

1. Sign in to the [Azure portal](https://portal.azure.com) with an account that has the permissions listed in [Prerequisites](#prerequisites).
2. Click the **Cloud Shell** icon (`>_`) in the top bar, or go to <https://shell.azure.com>.
3. Choose **Bash** (not PowerShell).
4. When asked about storage, choose **Mount storage account** so `~/` (your SSH key, the repo and `terraform.tfvars`) survives between sessions. An ephemeral session works, but you lose everything when it closes.

**Check:** the prompt looks like `you@Azure:~$` and these all print a version:
```bash
az version --query '"azure-cli"' -o tsv
```
```bash
terraform version
```
```bash
gh --version
```

> Cloud Shell disconnects after about **20 minutes without keyboard input**. `terraform apply` takes 10 to 20 minutes, so keep the tab in front and press a key now and then. State is stored remotely, so an interrupted apply is safe to re-run (see [Troubleshooting](#troubleshooting)).

### Step 2: Get the code

```bash
git clone https://github.com/mylesagnew/azure-syslog.git ~/azure-syslog
```
```bash
cd ~/azure-syslog/terraform
```

**Check:** `ls` shows `main.tf`, `variables.tf`, `terraform.tfvars.example` and the other Terraform files.

### Step 3: Select the subscription that will host the collectors

Cloud Shell is already signed in as you, so you do not need `az login`.

```bash
az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o table
```
```bash
az account set --subscription "<workload-subscription-id>"
```

This is the **workload** subscription (shared services, identity or management, depending on your Landing Zone design).

To deploy as a service principal instead (for example to use exactly the permissions a pipeline will have), export these before running Terraform:
```bash
export ARM_TENANT_ID="<tenant-id>" ARM_SUBSCRIPTION_ID="<workload-subscription-id>" ARM_CLIENT_ID="<app-id>" ARM_CLIENT_SECRET="<secret>"
```

**Check:**
```bash
az account show --query "{name:name, id:id, user:user.name}" -o table
```

### Step 4: Check your permissions

```bash
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

Compare the output with [Prerequisites](#prerequisites). The ones most often missing are:
- subnet **join** rights in the connectivity subscription
- **Private DNS Zone Contributor** on the zone
- rights to create **role assignments** (Key Vault Secrets User for the VM identity)

Ask the platform team for anything missing **before** you continue. A failure halfway through an apply is harder to unpick.

### Step 5: Register encryption at host (once per subscription)

```bash
az feature register --namespace Microsoft.Compute --name EncryptionAtHost
```
Then wait until this prints `Registered` (usually a few minutes):
```bash
az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv
```
Then refresh the provider:
```bash
az provider register --namespace Microsoft.Compute
```

If you are not allowed to register features, set `encryption_at_host_enabled = false` in Step 10 and record this as an exception.

### Step 6: Collect the Landing Zone details

Run these lookups and write down the values; they all go into `terraform.tfvars` in Step 10. Use `--subscription` to point at the subscription that owns each resource.

**a. Target VNet and subnet** (hub shared-services subnet or management spoke):
```bash
az network vnet list --subscription "<network-sub-id>" --query "[].{vnet:name, rg:resourceGroup, location:location}" -o table
```
```bash
az network vnet subnet list --subscription "<network-sub-id>" -g "<vnet-rg>" --vnet-name "<vnet-name>" --query "[].{subnet:name, prefix:addressPrefix}" -o table
```
→ `vnet_name`, `vnet_resource_group_name`, `subnet_name`, `network_subscription_id`

**b. Azure Bastion: subnet CIDR and SKU**
```bash
az network vnet subnet show --subscription "<network-sub-id>" -g "<hub-rg>" --vnet-name "<hub-vnet>" -n AzureBastionSubnet --query "addressPrefix || addressPrefixes[0]" -o tsv
```
```bash
az network bastion list --subscription "<network-sub-id>" --query "[].{name:name, rg:resourceGroup, sku:sku.name, nativeClient:enableTunneling}" -o table
```
→ `ssh_allowed_source_cidrs`, `bastion_name`, `bastion_resource_group_name`.
`az network bastion ssh` and `ansible_mode = "bastion_push"` need SKU **Standard** or **Premium** with `nativeClient = True`.

**c. Private DNS zone** (connectivity subscription):
```bash
az network private-dns zone list --subscription "<dns-sub-id>" --query "[].{zone:name, rg:resourceGroup}" -o table
```
→ `private_dns_zone_name`, `private_dns_zone_resource_group_name`, `dns_subscription_id`

**d. Log Analytics / Sentinel workspace** (management subscription):
```bash
az monitor log-analytics workspace list --subscription "<mgmt-sub-id>" --query "[].{name:name, rg:resourceGroup, location:location}" -o table
```
→ `log_analytics_workspace_name`, `log_analytics_workspace_resource_group_name`, `management_subscription_id`

**e. Key Vault** (for the TLS certificate on 6514):
```bash
az keyvault list --query "[].{name:name, rg:resourceGroup, rbac:properties.enableRbacAuthorization}" -o table
```
```bash
az keyvault show -n "<kv-name>" --query id -o tsv
```
→ `key_vault_id`. Set `key_vault_authorization` to `rbac` if `rbac` is `true`, otherwise to `access_policy`.

**f. Syslog source ranges:** list every CIDR that will send logs: spokes, on-premises ranges over ExpressRoute or VPN, and NVA subnets. → `syslog_allowed_source_cidrs`

**g. Confirm the Ubuntu 26.04 image is available in your region:**
```bash
az vm image list -l australiaeast -p Canonical -f ubuntu-26_04-lts -s server --all --query "[-1].{urn:urn, version:version}" -o table
```
The newest version should be dated after the 26.04.1 point release. If the list is empty, the region does not have the offer yet; choose another region or wait.

**h. Check the region supports zones for the VM size:**
```bash
az vm list-skus -l australiaeast --size Standard_D2as_v5 --query "[0].locationInfo[0].zones" -o tsv
```
An empty result means no zones: set `zones = []` and an Availability Set is used instead.

### Step 7: Create the admin SSH key

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/syslog_admin -N "" -C "syslog-lz-admin"
```
```bash
export TF_VAR_admin_ssh_public_key="$(cat ~/.ssh/syslog_admin.pub)"
```

The public key goes onto the VMs. The private key stays in your Cloud Shell home and never enters Terraform state.

> Re-run the `export` line every time you open a **new** Cloud Shell session, or add it to `~/.bashrc`.

### Step 8: Prepare remote state

If the Landing Zone already has a Terraform state storage account, use it. Otherwise create one:
```bash
../scripts/bootstrap-state.sh "<mgmt-sub-id>" rg-tfstate-prd-aue-001 sttfstateprdaue001 australiaeast
```

Then point the backend at it:
```bash
cp backend.hcl.example backend.hcl
```
```bash
code backend.hcl
```
Set `subscription_id`, `resource_group_name`, `storage_account_name`, `container_name` and `key`. Save with **Ctrl+S**.

You need **Storage Blob Data Contributor** on the container. No storage keys are used.

### Step 9: Provide the TLS certificate (skip if `enable_tls = false` or `tls_certificate_source = "selfsigned"`)

The collector reads the certificate from Key Vault with its managed identity. The secret **must** be PEM (`application/x-pem-file`).

**Option A: use your enterprise CA (recommended for production).** Issue a server certificate for `syslog.<your-zone>` plus each VM name, then import it as PEM into Key Vault under the name in `tls_keyvault_certificate_name` (default `syslog-collector-tls`).

**Option B: create a self-issued, auto-renewing certificate with the CLI:**
```bash
KV="<kv-name>"; FQDN="syslog.internal.contoso.com"
```
```bash
az keyvault certificate get-default-policy | jq --arg cn "CN=$FQDN" --arg dns "$FQDN" '.secretProperties.contentType="application/x-pem-file" | .x509CertificateProperties.subject=$cn | .x509CertificateProperties.subjectAlternativeNames={dnsNames:[$dns]} | .keyProperties.keySize=3072' > ~/syslog-cert-policy.json
```
```bash
az keyvault certificate create --vault-name "$KV" -n syslog-collector-tls -p @~/syslog-cert-policy.json
```

**Option C:** set `tls_keyvault_generate_certificate = true` and Terraform creates the certificate. This only works if Cloud Shell can reach the vault's data plane. Most Landing Zone vaults are private-endpoint only, so Option B run from a network that can reach the vault, or Option A, is usually easier.

**Check:**
```bash
az keyvault secret show --vault-name "$KV" -n syslog-collector-tls --query contentType -o tsv
```
It must print `application/x-pem-file`.

### Step 10: Fill in `terraform.tfvars`

```bash
cp terraform.tfvars.example terraform.tfvars
```
```bash
code terraform.tfvars
```

Work through the file top to bottom using the values from Step 6. The decisions that matter most:

| Setting | Typical production value |
|---|---|
| `vm_count` / `enable_internal_load_balancer` | `2` / `true` for HA; `1` / `false` for a single collector |
| `syslog_allowed_source_cidrs` | Only your real sender ranges. `0.0.0.0/0` is rejected |
| `ssh_allowed_source_cidrs` | The AzureBastionSubnet prefix only |
| `ansible_mode` | `cse` (no network path from Cloud Shell needed) |
| `tls_certificate_source` | `keyvault` for 2 or more VMs, `selfsigned` for a lab |
| `dcr_syslog_log_levels` | Start at `Notice` and above to control Log Analytics cost |
| `tags` | Must include `Owner` and `CostCenter` |

Save with **Ctrl+S** and close the editor with **Ctrl+Q**.

### Step 11: Initialise and validate

```bash
terraform init -backend-config=backend.hcl
```
```bash
terraform fmt -check -recursive && terraform validate
```

**Check:** `init` ends with *Terraform has been successfully initialized* and `validate` prints *The configuration is valid*.

### Step 12: Plan and review

```bash
terraform plan -out tfplan
```

Read the plan before applying. Expect **only creates**, roughly per VM:
- VM, NIC, OS disk, log disk and disk attachment
- extensions (AMA, ansible-bootstrap)
- DCR association, DNS record, role assignment, diagnostic settings

Plus, shared by all VMs: the RG, NSG and rules, ASG, LB (if enabled) and DCR.

Stop and investigate if the plan wants to **change or destroy** anything you did not expect. That would point to an existing Landing Zone resource being referenced wrongly.

Precondition errors at this stage explain exactly which variable is missing (for example `key_vault_id is required when tls_certificate_source = keyvault`).

### Step 13: Apply

```bash
terraform apply tfplan
```

This takes about 10 to 20 minutes. The longest resource is `azurerm_virtual_machine_extension.ansible`: the VM installs packages and runs the playbook. To watch progress from a **second** Cloud Shell tab:
```bash
az vm extension list -g rg-syslog-prd-aue-001 --vm-name vm-syslog-prd-aue-01 --query "[].{name:name, state:provisioningState}" -o table
```

**Check:** the apply ends with `Apply complete!` and prints the outputs.

### Step 14: Record the outputs

```bash
terraform output
```
```bash
terraform output -raw syslog_endpoint_ip
```
```bash
terraform output syslog_dns_name
```

Give the platform and security teams:
- `syslog_dns_name`: what every sender should use
- `collector_private_ips`
- `application_security_group_id`: to use in hub firewall or subnet NSG rules

### Step 15: Validate the collectors

```bash
../scripts/validate.sh
```

For each VM this runs, through the Azure control plane:
- rsyslog health and a config check
- the 514/6514 listeners and the ufw rules
- the log-disk mount
- a UDP and TCP self-test

**Check** that for every VM:
- `rsyslog` shows `active`
- there are listeners on `:514` (udp and tcp) and `:6514`
- the `--- received` section shows **two** `lz-syslog-selftest` lines
- `azuremonitoragent` shows `active`

### Step 16: Test from a real sender

From any Linux host inside `syslog_allowed_source_cidrs`:
```bash
logger --server syslog.internal.contoso.com --port 514 --udp "lz-syslog-test udp"
```
```bash
logger --server syslog.internal.contoso.com --port 514 --tcp "lz-syslog-test tcp"
```
```bash
openssl s_client -connect syslog.internal.contoso.com:6514 -brief </dev/null
```

Or copy `scripts/test-syslog-client.sh` to that host and run it with the collector name as the argument.

Then look on a collector. Connect with the command from `terraform output bastion_ssh_commands`, then:
```bash
sudo ls /var/log/remote/
```
```bash
sudo grep -r "lz-syslog-test" /var/log/remote/
```

If nothing arrives, check in this order:
1. the sender's own egress rules
2. the subnet NSG (owned by the Landing Zone)
3. the hub firewall
4. this deployment's NIC NSG

The NIC NSG and ufw only allow the CIDRs you listed.

### Step 17: Confirm data in Log Analytics / Sentinel

Allow 5 to 10 minutes after the first message, then in the workspace go to **Logs** and run:
```kusto
Syslog
| where TimeGenerated > ago(30m)
| where SyslogMessage has "lz-syslog-test"
| project TimeGenerated, HostName, HostIP, Facility, SeverityLevel, SyslogMessage
```

In Sentinel, install the **Syslog** solution from the Content Hub (and **Common Event Format** if you set `dcr_cef_facilities`). The *Syslog via AMA* connector page will list the DCR `dcr-syslog-<env>-<region>-001`.

`logger` sends at level `notice`. If you changed `dcr_syslog_log_levels` to `Warning` or higher, add `-p user.warning` to the test.

### Step 18: Point your log sources at the collector

**Linux (rsyslog)**: create `/etc/rsyslog.d/90-forward.conf` on the sender:
```
# TCP with a disk-assisted queue (survives collector restarts)
*.* action(type="omfwd" target="syslog.internal.contoso.com" port="514" protocol="tcp"
           queue.type="LinkedList" queue.filename="fwd" queue.saveOnShutdown="on"
           action.resumeRetryCount="-1")
```
Then restart rsyslog:
```bash
sudo systemctl restart rsyslog
```

**Linux over TLS (6514)**: install `rsyslog-gnutls` on the sender and copy the collector's CA (or its self-issued certificate) to `/etc/rsyslog-ca.pem`. Then use:
```
global(DefaultNetstreamDriverCAFile="/etc/rsyslog-ca.pem")
*.* action(type="omfwd" target="syslog.internal.contoso.com" port="6514" protocol="tcp"
           StreamDriver="gtls" StreamDriverMode="1" StreamDriverAuthMode="x509/name"
           StreamDriverPermittedPeers="syslog.internal.contoso.com")
```

**Network appliances / firewalls**: set the syslog server to `syslog.internal.contoso.com`, or to the IP from `syslog_endpoint_ip`, on UDP or TCP 514. For CEF, use the facility you set in `dcr_cef_facilities`.

### Step 19: Day-2 changes

| Task | How |
|---|---|
| Change rsyslog or hardening settings | Edit `ansible/` or `terraform.tfvars`, then `terraform plan -out tfplan && terraform apply tfplan`. The extension re-runs automatically |
| Add a sender range | Append to `syslog_allowed_source_cidrs` and apply. Both the NSG and ufw are updated |
| Scale out | Increase `vm_count` (and set `enable_internal_load_balancer = true`), then apply |
| Pick up a renewed certificate now | On the VM: `sudo systemctl start syslog-lz-converge.service`. Otherwise the weekly timer does it |
| Patch status | Azure Update Manager shows assessment results. Security updates install automatically |

### Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `init` fails with 403 on the state blob | You need **Storage Blob Data Contributor** on the state container |
| Playbook stops at *Confirm Ubuntu 26.04 LTS at the required point release* | The VM is not on 26.04.1 or later. Check `source_image` is `Canonical:ubuntu-26_04-lts:server:latest`, or run `sudo apt-get update && sudo apt-get full-upgrade -y` on the VM and re-run `terraform apply` |
| AMA extension fails to install | Ubuntu 26.04 may not be on the AMA supported list yet (see [Operating system](#operating-system-ubuntu-26041-lts)). Set `enable_ama = false` for now |
| Plan fails with `AuthorizationFailed` on the subnet, DNS zone or workspace | The wrong `*_subscription_id`, or missing read or join rights in that subscription |
| `EncryptionAtHost` error on VM create | Step 5 has not finished, or the feature is blocked. Wait for `Registered` or set `encryption_at_host_enabled = false` |
| `ansible-bootstrap` extension fails | On the VM, read `/var/log/syslog-lz-bootstrap.log`. From Cloud Shell: `az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts "tail -n 80 /var/log/syslog-lz-bootstrap.log"`. The most common cause is no egress to the Ubuntu mirrors through the hub firewall |
| Key Vault task retries then fails | Role assignment still propagating (re-run `terraform apply`), the vault private endpoint is not resolvable from the subnet, or the secret is not PEM (see Step 9) |
| No data in Log Analytics but files appear on disk | AMA has no egress to the `*.handler.control.monitor.azure.com` and `*.ods.opinsights.azure.com` endpoints (or your AMPLS), or the severity is below `dcr_syslog_log_levels` |
| `Error acquiring the state lock` after a dropped Cloud Shell session | Confirm nobody else is running Terraform, then `terraform force-unlock <lock-id>` and re-run the plan and apply |
| `az network bastion ssh` fails | Bastion must be Standard or Premium with native client support. Basic SKU works through the portal only |


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
