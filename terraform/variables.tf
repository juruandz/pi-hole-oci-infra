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

# --- Pi-hole -----------------------------------------------------------------

variable "pihole_web_password" {
  description = "Pi-hole admin password. Leave empty to have a random one generated on the instance (retrieve it with `sudo cat /root/pihole-web-password`)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "pihole_upstream_dns" {
  description = "Upstream DNS resolvers for Pi-hole. The first two are used; the first is required."
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]

  validation {
    condition     = length(var.pihole_upstream_dns) > 0
    error_message = "Provide at least one upstream DNS resolver."
  }
}

variable "pihole_dnssec" {
  description = "Enable DNSSEC validation in Pi-hole"
  type        = bool
  default     = false
}

# --- WireGuard ---------------------------------------------------------------

variable "wireguard_address" {
  description = "WireGuard server address including prefix length"
  type        = string
  default     = "10.182.229.1/24"
}

variable "wireguard_subnet" {
  description = "WireGuard subnet, used for the MASQUERADE (NAT) rule"
  type        = string
  default     = "10.182.229.0/24"
}

variable "wireguard_port" {
  description = "WireGuard UDP listen port"
  type        = number
  default     = 51820
}

variable "wireguard_mtu" {
  description = "WireGuard interface MTU. 1280 is a safe value for mobile clients."
  type        = number
  default     = 1280
}

variable "wireguard_clients" {
  description = "Initial WireGuard peers created via `pivpn add`. Only created when the client config is missing, so re-applies never overwrite keys. Manage peers afterwards with `pivpn add` on the instance."
  type = list(object({
    name = string
    ip   = string
  }))
  default = []
}

variable "pivpn_version" {
  description = "PiVPN release to install. Pinned so a deploy is reproducible; bump deliberately."
  type        = string
  default     = "v4.11.1"
}

# --- DDNS --------------------------------------------------------------------

variable "ddns_install_oci_cli" {
  description = "Install the OCI CLI in a venv on the instance so the DDNS updater can run"
  type        = bool
  default     = true
}

variable "reboot_after_setup" {
  description = "Reboot the instance at the end of provisioning so kernel and service updates take effect"
  type        = bool
  default     = true
}

