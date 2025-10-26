# Get the private IP of the instance
data "oci_core_vnic_attachments" "pihole_vnic_attachments" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.pihole_instance.id
}

data "oci_core_private_ips" "pihole_private_ips" {
  vnic_id = data.oci_core_vnic_attachments.pihole_vnic_attachments.vnic_attachments[0].vnic_id
}

# Create and assign a reserved public IP to the instance's private IP
resource "oci_core_public_ip" "pihole_public_ip" {
  compartment_id = var.compartment_id
  lifetime       = "RESERVED"
  display_name   = "pihole-reserved-ip"
  private_ip_id  = data.oci_core_private_ips.pihole_private_ips.private_ips[0].id
}

# Run setup script after public IP is assigned
resource "null_resource" "setup_provisioner" {
  provisioner "file" {
    source      = "${path.module}/../scripts/setup.sh"
    destination = "/tmp/setup.sh"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = var.ssh_private_key
      host        = oci_core_public_ip.pihole_public_ip.ip_address
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup.sh",
      "sudo bash /tmp/setup.sh"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = var.ssh_private_key
      host        = oci_core_public_ip.pihole_public_ip.ip_address
    }
  }

  depends_on = [oci_core_public_ip.pihole_public_ip]
}