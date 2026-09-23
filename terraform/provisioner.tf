# Run setup script after public IP is assigned
resource "null_resource" "setup_provisioner" {
  # Re-provision when the script changes or the instance is replaced
  triggers = {
    script_hash = filesha256("${path.module}/../scripts/setup.py")
    instance_id = oci_core_instance.pihole_instance.id
  }

  provisioner "file" {
    source      = "${path.module}/../scripts/setup.py"
    destination = "/tmp/setup.py"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = var.ssh_private_key
      host        = oci_core_public_ip.pihole_public_ip.ip_address
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y python3",
      "sudo python3 /tmp/setup.py"
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