terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source = "oracle/oci"
    }
    random = {
      source = "hashicorp/random"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "oci" {
  # Defaults to API-key auth from ~/.oci/config (unchanged behavior). Set
  # oci_auth = "SecurityToken" (+ run `oci session authenticate`) to use a
  # browser/session token instead.
  auth                = var.oci_auth
  config_file_profile = var.oci_config_profile
  region              = var.oci_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
