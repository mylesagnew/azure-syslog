terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = ">= 1.4, < 2.0"
    }
  }

  # Bootstrap state can live next to the main state (different key):
  #   terraform init -backend-config=backend.hcl
  backend "azurerm" {
    use_azuread_auth = true
  }
}
