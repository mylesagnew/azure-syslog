# Run once from Cloud Shell by someone who can create identities and role
# assignments (Owner, or Contributor + Role Based Access Control Administrator)
# and who is a Project Administrator in Azure DevOps.
#
# Azure DevOps auth: export AZDO_PERSONAL_ACCESS_TOKEN with scopes
#   Service Connections (Read, query & manage), Environment (Read & manage),
#   Variable Groups (Read, create & manage), Project and Team (Read), Identity (Read)
# and AZDO_ORG_SERVICE_URL=https://dev.azure.com/<org> (or set var.azuredevops_org_url).

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  features {}
}

provider "azuredevops" {
  org_service_url = var.azuredevops_org_url
}
