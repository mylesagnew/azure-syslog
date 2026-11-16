#!/usr/bin/env bash
# Optional: create the Terraform state storage account if the Landing Zone does
# not already provide one. Entra ID auth only - shared keys disabled.
#   ./bootstrap-state.sh <subscription> <rg> <storage-account> [location]
set -euo pipefail
SUB="${1:?subscription}"; RG="${2:?resource group}"; SA="${3:?storage account}"; LOC="${4:-australiaeast}"

az group create --subscription "$SUB" -n "$RG" -l "$LOC" -o none
az storage account create --subscription "$SUB" -g "$RG" -n "$SA" -l "$LOC" \
  --sku Standard_ZRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false -o none
az storage account blob-service-properties update --subscription "$SUB" -g "$RG" \
  --account-name "$SA" --enable-versioning true --enable-delete-retention true --delete-retention-days 30 -o none

SA_ID="$(az storage account show --subscription "$SUB" -g "$RG" -n "$SA" --query id -o tsv)"
az role assignment create --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Storage Blob Data Contributor" --scope "$SA_ID" -o none || true
sleep 30 # RBAC propagation
az storage container create --account-name "$SA" -n tfstate --auth-mode login -o none
echo "State storage ready: $SA/tfstate"
