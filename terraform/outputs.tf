output "public_ip" {
  description = "The public IP address of the Pi-hole instance"
  value       = oci_core_public_ip.pihole_public_ip.ip_address
}

output "instance_id" {
  description = "OCID of the Pi-hole compute instance"
  value       = oci_core_instance.pihole_instance.id
}

output "private_ip" {
  description = "Private IP address of the Pi-hole instance"
  value       = data.oci_core_private_ips.pihole_private_ips.private_ips[0].ip_address
}

output "availability_domain" {
  description = "Availability domain the instance was placed in"
  value       = local.availability_domain
}

output "ddns_security_list_id" {
  description = "OCID of the DDNS-managed security list. Set this as the security list target in the on-host update_ddns job."
  value       = oci_core_security_list.ddns_security_list.id
}

output "ssh_command" {
  description = "SSH command for the instance"
  value       = "ssh -p ${var.ssh_port} ubuntu@${oci_core_public_ip.pihole_public_ip.ip_address}"
}

# output "pihole_admin_url" {
#   description = "URL for Pi-hole admin interface"
#   value       = "https://${oci_core_public_ip.pihole_public_ip.ip_address}/admin"
# }
