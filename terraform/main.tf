# Network resources
resource "oci_core_vcn" "pihole_vcn" {
  compartment_id = var.compartment_id
  cidr_block     = "10.0.0.0/16"
  display_name   = "pihole-vcn"
  dns_label      = "piholevcn"
}

resource "oci_core_security_list" "default_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.pihole_vcn.id
  # manage_default_resource_id = oci_core_vcn.pihole_vcn.default_security_list_id
  display_name = "default_security_list"

  # NOTE: deliberately NO SSH rule here. Anything that depends on the home IP
  # (SSH, DNS, admin UI, ping) lives in the DDNS-managed security list below,
  # whose ingress sources are rewritten to the current home IP by the DDNS
  # cron job. A world-open tcp/22 rule used to sit here; it is gone on purpose.

  # Allow ICMP type 3 code 4 from anywhere
  ingress_security_rules {
    protocol  = "1" # ICMP
    source    = "0.0.0.0/0"
    stateless = false

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Allow ICMP type 3 (no code) from VCN
  ingress_security_rules {
    protocol  = "1" # ICMP
    source    = "10.0.0.0/16"
    stateless = false

    icmp_options {
      type = 3
    }
  }

  # Allow WireGuard VPN
  ingress_security_rules {
    protocol    = "17" # UDP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "WireGuard VPN"

    udp_options {
      min = 51820
      max = 51820
    }
  }

  # Allow all egress traffic (required for package downloads and internet access)
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

resource "oci_core_internet_gateway" "internet_gateway" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.pihole_vcn.id
  display_name   = "pihole-internet-gateway"
}

resource "oci_core_route_table" "route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.pihole_vcn.id
  display_name   = "pihole-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.internet_gateway.id
  }
}

# Custom Security List
# Home-IP-dependent access. The on-host update_ddns.py cron job rewrites the
# `source` of EVERY ingress rule in this list to the current DDNS-resolved home
# IP, so var.allowed_ip is only the initial seed value.
resource "oci_core_security_list" "ddns_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.pihole_vcn.id
  display_name   = "pihole-ddns-security-list"

  # Allow SSH from the home IP
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.allowed_ip
    stateless   = false
    description = "SSH from home IP"

    tcp_options {
      min = var.ssh_port
      max = var.ssh_port
    }
  }

  # Allow DNS over TCP from the home IP.
  # Must be a 53-to-53 rule: a min/max range (previously 53-443) opens every
  # port in between, not just the two endpoints.
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.allowed_ip
    stateless   = false
    description = "DNS over TCP"

    tcp_options {
      min = 53
      max = 53
    }
  }

  # Allow the Pi-hole admin UI / DoH from the home IP
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.allowed_ip
    stateless   = false
    description = "Pi-hole admin UI"

    tcp_options {
      min = 443
      max = 443
    }
  }

  # Allow DNS over UDP from the home IP
  ingress_security_rules {
    protocol    = "17" # UDP
    source      = var.allowed_ip
    stateless   = false
    description = "DNS over UDP"

    udp_options {
      min = 53
      max = 53
    }
  }

  # Allow ICMP from the home IP
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = var.allowed_ip
    stateless   = false
    description = "ICMP from home IP"
  }

  # Allow all egress traffic (required for package downloads and internet access)
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }

}

# Subnet
resource "oci_core_subnet" "subnet" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.pihole_vcn.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "pihole-subnet"
  dns_label      = "piholesubnet"

  security_list_ids = [
    oci_core_security_list.default_security_list.id,
    oci_core_security_list.ddns_security_list.id
  ]
  route_table_id = oci_core_route_table.route_table.id
}

# Get availability domains 
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

locals {
  # var.availability_domain wins when set (non-empty); otherwise use the first AD.
  # Setting the variable explicitly lets you retry another AD when
  # VM.Standard.E2.1.Micro capacity is unavailable in the first one.
  availability_domain = coalesce(
    var.availability_domain,
    data.oci_identity_availability_domains.ads.availability_domains[0].name
  )
}

# Compute Instance
data "oci_core_images" "ubuntu_images" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "pihole_instance" {
  availability_domain = local.availability_domain
  compartment_id      = var.compartment_id
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet.id
    assign_public_ip = false # We'll use the reserved public IP instead
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_images.images[0].id
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(<<-EOF
#cloud-config
write_files:
  - path: /etc/systemd/system/zram-swap.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Setup zram swap
      After=network.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStartPre=/sbin/modprobe zram num_devices=1
      ExecStart=/bin/sh -c "echo 524288000 > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon /dev/zram0"

      [Install]
      WantedBy=multi-user.target
runcmd:
  - fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  - chmod 600 /swapfile
  - mkswap /swapfile
  - swapon /swapfile
  - echo '/swapfile none swap sw 0 0' >> /etc/fstab
  - sysctl -w vm.swappiness=10
  - echo 'vm.swappiness=10' >> /etc/sysctl.conf
  - systemctl daemon-reload
  - systemctl enable --now zram-swap.service
EOF
    )
  }

  display_name = "pihole-wireguard-server"
}