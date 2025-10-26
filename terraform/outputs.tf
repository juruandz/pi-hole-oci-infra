output "public_ip" {
  description = "The public IP address of the Pi-hole instance"
  value       = oci_core_public_ip.pihole_public_ip.ip_address
}

# output "pihole_admin_url" {
#   description = "URL for Pi-hole admin interface"
#   value       = "http://${oci_core_public_ip.pihole_public_ip.ip_address}/admin"
# }

# output "security_list_id" {
#   description = "OCID of the custom security list for DDNS updates"
#   value       = oci_core_security_list.security_list.id
# }