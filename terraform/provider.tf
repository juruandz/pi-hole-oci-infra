terraform {
  # optional() object attributes in var.wireguard_clients require Terraform 1.3+;
  # 1.5 is required for the configuration as documented.
  required_version = ">= 1.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 4.0"
    }
  }
}

provider "oci" {
  # Authentication will be configured through environment variables or config file
  region = var.region
}