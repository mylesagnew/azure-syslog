# Remote state in the Landing Zone's state storage account (usually in the
# management subscription). Values are supplied at init time so nothing
# environment-specific is committed:
#
#   terraform init -backend-config=backend.hcl
#
# See backend.hcl.example. Entra ID auth is used - no storage account keys.
# The caller needs "Storage Blob Data Contributor" on the state container.
terraform {
  backend "azurerm" {
    use_azuread_auth = true
  }
}
