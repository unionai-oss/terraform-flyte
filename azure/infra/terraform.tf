terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.12"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    # Declared only so the tests can mock it: the AVM modules require it for their telemetry resources, which
    # are switched off here (enable_telemetry = false), and a mock_provider block resolves names through this file.
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}
