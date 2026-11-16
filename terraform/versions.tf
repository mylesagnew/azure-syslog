terraform {
  # Cloud Shell ships a current Terraform; 1.6+ is needed for the features used here.
  required_version = ">= 1.6.0"

  required_providers {
    # The prompt baseline is azurerm >= 3.100. This code targets the 4.x schema
    # (accelerated_networking_enabled, tcp_reset_enabled, resource_provider_registrations ...).
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
    # Packages the ../ansible tree into the Custom Script Extension payload.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    # Only used when ansible_mode = "bastion_push" (local-exec from Cloud Shell).
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
