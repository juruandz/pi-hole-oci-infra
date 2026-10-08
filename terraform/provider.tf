terraform {
  # optional() object attributes in var.wireguard_clients require Terraform 1.3+;
  # 1.5 is required for the configuration as documented.
  required_version = ">= 1.5"

  # State is LOCAL by default: this is a single-operator project, so no shared
  # backend is needed. Uncomment below to keep state in OCI Object Storage
  # instead (off-box backup/history). `bucket` and `namespace` cannot be set
  # via environment variables; prefer partial configuration
  # (`terraform init -backend-config=backend.hcl`) over hardcoding them here.
  # Locking is supported by this backend, but for solo use the point is
  # versioned backup -- enable bucket versioning if you adopt it.
  #
  # backend "oci" {
  #   bucket    = "terraform-state"       # required
  #   namespace = "your-namespace"        # required
  #   key       = "pihole-oci/terraform.tfstate"
  #   region    = "eu-stockholm-1"
  #   # kms_key_id = "ocid1.key.oc1..xxx" # optional: encrypt the state object
  # }

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }
}

provider "oci" {
  # Authentication will be configured through environment variables or config file
  region = var.region
}