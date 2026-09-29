locals {
  # Rendered to /tmp/provision-vars.json on the instance and read by
  # scripts/setup.py. jsonencode() guarantees valid JSON, so there is no
  # template quoting to get wrong, and no secret is stored in the repo.
  provision_config = {
    ssh_port = var.ssh_port

    pihole = {
      ipv4_address = "${data.oci_core_private_ips.pihole_private_ips.private_ips[0].ip_address}/24"
      web_password = var.pihole_web_password
      upstream_dns = var.pihole_upstream_dns
      dnssec       = var.pihole_dnssec
    }

    wireguard = {
      endpoint = oci_core_public_ip.pihole_public_ip.ip_address
      address  = var.wireguard_address
      subnet   = var.wireguard_subnet
      port     = var.wireguard_port
      mtu      = var.wireguard_mtu
      version  = var.pivpn_version
      clients  = var.wireguard_clients
    }

    ddns = {
      enabled          = var.ddns_host != ""
      host             = var.ddns_host
      security_list_id = oci_core_security_list.ddns_security_list.id
      region           = var.region
      install_oci_cli  = var.ddns_install_oci_cli
    }

    reboot_after_setup = var.reboot_after_setup
  }
}

# Run setup script after public IP is assigned
resource "null_resource" "setup_provisioner" {
  # Re-provision when any input changes. config_hash covers every value that
  # setup.py consumes, so a tfvars edit is picked up without touching the
  # script itself.
  triggers = {
    script_hash = filesha256("${path.module}/../scripts/setup.py")
    ddns_hash   = filesha256("${path.module}/../scripts/conf/update_ddns.py")
    reboot_hash = filesha256("${path.module}/../scripts/conf/nightly_reboot_check.py")
    config_hash = sha256(jsonencode(local.provision_config))
    instance_id = oci_core_instance.pihole_instance.id
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    port        = var.ssh_port
    private_key = var.ssh_private_key
    host        = oci_core_public_ip.pihole_public_ip.ip_address
  }

  # Deployment settings (contains the Pi-hole web password, hence mode 600 below)
  provisioner "file" {
    content     = jsonencode(local.provision_config)
    destination = "/tmp/provision-vars.json"
  }

  provisioner "file" {
    source      = "${path.module}/../scripts/setup.py"
    destination = "/tmp/setup.py"
  }

  provisioner "file" {
    source      = "${path.module}/../scripts/conf/update_ddns.py"
    destination = "/tmp/update_ddns.py"
  }

  provisioner "file" {
    source      = "${path.module}/../scripts/conf/nightly_reboot_check.py"
    destination = "/tmp/nightly_reboot_check.py"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /tmp/provision-vars.json",
      "command -v python3 >/dev/null || (sudo apt-get update && sudo apt-get install -y python3)",
      "sudo python3 /tmp/setup.py",
    ]
  }

  depends_on = [oci_core_public_ip.pihole_public_ip]
}