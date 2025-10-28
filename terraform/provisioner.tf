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
      "sudo apt-get update",
      "sudo apt-get install dos2unix -y",
      "dos2unix /tmp/setup.sh || sed -i 's/\r$//' /tmp/setup.sh",
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