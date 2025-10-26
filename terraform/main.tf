# Network resources
resource "oci_core_vcn" "pihole_vcn" {
  compartment_id = var.compartment_id
  cidr_block     = "10.0.0.0/16"
  display_name   = "pihole-vcn"
  dns_label      = "piholevcn"
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
resource "oci_core_security_list" "security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.pihole_vcn.id
  display_name   = "pihole-security-list"

  # Allow all TCP from specific IP
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = var.allowed_ip
    stateless = false
  }

  # Allow all UDP from specific IP
  ingress_security_rules {
    protocol  = "17" # UDP
    source    = var.allowed_ip
    stateless = false
  }

  # Allow ICMP from specific IP
  ingress_security_rules {
    protocol  = "1" # ICMP
    source    = var.allowed_ip
    stateless = false
  }

  # Allow all outbound traffic
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }
}

# WireGuard Security List
resource "oci_core_security_list" "wireguard_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.pihole_vcn.id
  display_name   = "wireguard-security-list"

  # # Allow SSH from anywhere
  # ingress_security_rules {
  #   protocol  = "6" # TCP
  #   source    = "0.0.0.0/0"
  #   stateless = false
    
  #   tcp_options {
  #     min = 22
  #     max = 22
  #   }
  # }

  # # Allow ICMP type 3 code 4 from anywhere
  # ingress_security_rules {
  #   protocol  = "1" # ICMP
  #   source    = "0.0.0.0/0"
  #   stateless = false
    
  #   icmp_options {
  #     type = 3
  #     code = 4
  #   }
  # }

  # # Allow ICMP type 3 (no code) from VCN
  # ingress_security_rules {
  #   protocol  = "1" # ICMP
  #   source    = "10.0.0.0/16"
  #   stateless = false
    
  #   icmp_options {
  #     type = 3
  #   }
  # }

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

  # # Allow all outbound traffic
  # egress_security_rules {
  #   destination = "0.0.0.0/0"
  #   protocol    = "all"
  #   stateless   = false
  # }
}

# Subnet
resource "oci_core_subnet" "subnet" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.pihole_vcn.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "pihole-subnet"
  dns_label      = "piholesubnet"
  
  security_list_ids = [
    oci_core_security_list.security_list.id,
    oci_core_security_list.wireguard_security_list.id
  ]
  route_table_id    = oci_core_route_table.route_table.id
}

# Get availability domains 
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
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
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet.id
    assign_public_ip = false  # We'll use the reserved public IP instead
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_images.images[0].id
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    # user_data = base64encode(
    #   replace(
    #     replace(
    #       replace(
    #         file("${path.module}/../scripts/setup.sh"),
    #         "SECURITY_LIST_OCID_PLACEHOLDER",
    #         oci_core_security_list.security_list.id
    #       ),
    #       "DDNS_HOST_PLACEHOLDER",
    #       var.ddns_host
    #     ),
    #     "REGION_PLACEHOLDER",
    #     var.region
    #   )
    # )
  }

  display_name = "pihole-wireguard-server"
}