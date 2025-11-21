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

provider "oci" {}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
