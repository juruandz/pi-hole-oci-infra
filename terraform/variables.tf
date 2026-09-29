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
  description = "Availability domain NAME to deploy into (e.g. \"YbUn:EU-STOCKHOLM-1-AD-1\"). Leave empty to use the first AD returned for the region. Set this explicitly when E2.1.Micro capacity is unavailable in the first AD."
  type        = string
  default     = ""
}

variable "instance_shape" {
  description = "The shape of compute instance to launch"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "ssh_public_key" {
  description = "The SSH public key to use for the instance"
  type        = string
  sensitive   = false
}

variable "ssh_private_key" {
  description = "The SSH private key to use for provisioning"
  type        = string
  sensitive   = true
}

variable "allowed_ip" {
  description = "Initial home IP allowed to reach SSH/DNS/admin UI, in CIDR notation (use a /32). The DDNS cron job rewrites this to the live home IP after deployment."
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_ip, 0)) && endswith(var.allowed_ip, "/32")
    error_message = "allowed_ip must be a single host CIDR such as \"78.56.206.98/32\"."
  }
}

variable "ddns_host" {
  description = "The DDNS hostname to use for security list updates"
  type        = string
  default     = ""
}

variable "ssh_port" {
  description = "SSH port allowed from the home IP and used by the provisioning connection"
  type        = number
  default     = 22
}
