variable "region" {
  description = "The OCI region to deploy resources into"
  type        = string
  default     = "eu-stockholm-1" # Current region where existing VM is deployed
}

variable "compartment_id" {
  description = "The OCID of the compartment to create resources in"
  type        = string
}

variable "availability_domain" {
  description = "The availability domain to create resources in"
  type        = string
  default     = "1"
}

variable "instance_shape" {
  description = "The shape of compute instance to launch"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "ssh_public_key" {
  description = "The SSH public key to use for the instance"
  type        = string
}

variable "ssh_private_key" {
  description = "The SSH private key to use for provisioning"
  type        = string
  sensitive   = true
}

variable "allowed_ip" {
  description = "The IP address allowed to access the instance (format: IP/32)"
  type        = string
  default     = "0.0.0.0/0"  # Default to all IPs, but should be restricted in tfvars
}

variable "ddns_host" {
  description = "The DDNS hostname to use for security list updates"
  type        = string
  default     = ""
}