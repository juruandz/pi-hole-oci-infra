# Associate the reserved public IP with the instance's primary VNIC
resource "oci_core_public_ip" "pihole_public_ip" {
  compartment_id = var.compartment_id
  lifetime      = "RESERVED"
  display_name  = "pihole-static-ip"
  private_ip_id = data.oci_core_private_ips.pihole_private_ips.private_ips[0].id
}

# Get the private IP of the instance
data "oci_core_vnic_attachments" "pihole_vnic_attachments" {
  compartment_id = var.compartment_id
  instance_id   = oci_core_instance.pihole_instance.id
}

data "oci_core_private_ips" "pihole_private_ips" {
  vnic_id = data.oci_core_vnic_attachments.pihole_vnic_attachments.vnic_attachments[0].vnic_id
}