# Pi-hole and WireGuard on OCI

This repository contains Infrastructure as Code (IaC) for deploying a Pi-hole DNS server with WireGuard VPN on Oracle Cloud Infrastructure (OCI) using the Always Free tier VM.Standard.E2.1.Micro instance.

## Prerequisites

1. [OCI Account](https://www.oracle.com/cloud/free/) with access to create compute instances
2. [Terraform](https://www.terraform.io/downloads.html) installed locally
3. [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) configured with your credentials

## Configuration

1. Create a `terraform.tfvars` file with your OCI configuration:

```hcl
compartment_id     = "ocid1.compartment.oc1..example"
region            = "us-phoenix-1"  # Or your preferred region
availability_domain = "1"  # Check your region's availability domains
ssh_public_key    = "ssh-rsa AAAA..."  # Your SSH public key
```

## Deployment

1. Initialize Terraform:
```bash
terraform init
```

2. Plan the deployment:
```bash
terraform plan
```

3. Apply the configuration:
```bash
terraform apply
```

## Post-deployment

After deployment, you'll receive:
- Public IP address of your instance
- URL for Pi-hole admin interface

### WireGuard Client Configuration

To configure a WireGuard client:

1. SSH into the server to get the server's public key:
```bash
ssh ubuntu@<server-ip> "sudo cat /etc/wireguard/public.key"
```

2. Create a client configuration file:
```ini
[Interface]
PrivateKey = <generated-client-private-key>
Address = 10.8.0.2/24
DNS = 10.8.0.1

[Peer]
PublicKey = <server-public-key>
Endpoint = <server-ip>:51820
AllowedIPs = 0.0.0.0/0
```

## Security Notes

- The deployment creates security rules for:
  - SSH (port 22)
  - DNS (port 53 TCP/UDP)
  - WireGuard (port 51820 UDP)
  - Pi-hole admin interface (port 80)
- Consider restricting access to your IP address in the security rules
- Change default Pi-hole admin password

## License

MIT