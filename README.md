# Pi-hole and WireGuard on OCI

Infrastructure as Code for a Pi-hole v6 DNS server with WireGuard VPN on an Oracle
Cloud Infrastructure Always Free `VM.Standard.E2.1.Micro` instance.

Terraform builds the network (VCN, subnet, internet gateway, route table, a
reserved public IP) and the instance. `scripts/setup.py` then provisions the
server over SSH: Pi-hole v6, WireGuard with generated client configs, fail2ban,
a weekly reboot check, and optionally a DDNS job that keeps the security list
pointed at your home IP.

## Repository layout

| Path | Purpose |
| --- | --- |
| `terraform/` | Terraform root module. Run Terraform from this directory. |
| `scripts/setup.py` | Provisioning entry point, executed on the instance by `null_resource.setup_provisioner`. |
| `scripts/conf/` | Files copied to the instance (the DDNS updater and the reboot check). |
| `Makefile` | Convenience wrappers around the Terraform commands. |

## Prerequisites

1. An OCI tenancy where you can create networking and compute resources.
2. [Terraform](https://developer.hashicorp.com/terraform/install) **1.5 or newer**
   (the WireGuard client variable uses `optional()` object attributes).
3. OCI API credentials in `~/.oci/config`. The Terraform provider reads these
   directly; the OCI CLI itself is only needed for the DDNS credentials step below.
4. An SSH keypair for the instance.
5. Optional: a DDNS hostname (for example an Asus router's `asuscomm.com` name).
   Required if you want the security list to follow a changing home IP.

## Configuration

Create `terraform/terraform.tfvars` (gitignored) starting from
`terraform/terraform.tfvars.example`:

| Variable | Default | Notes |
| --- | --- | --- |
| `compartment_id` | – | Required. Compartment to deploy into. |
| `region` | `eu-stockholm-1` | Must match your tenancy's region. |
| `availability_domain` | `""` | AD **name** (e.g. `YbUn:EU-STOCKHOLM-1-AD-1`). Empty uses the first AD. Set it explicitly to retry another AD when `E2.1.Micro` capacity is unavailable. |
| `instance_shape` | `VM.Standard.E2.1.Micro` | Always Free shape. |
| `allowed_ip` | – | Required. Your home IP as a `/32`. Seeded into the DDNS-managed security list, which then tracks your IP automatically. |
| `ssh_port` | `22` | Port allowed from `allowed_ip` and used by the provisioning connection. |
| `ssh_public_key` | – | Required. Injected into the instance. |
| `ssh_private_key` | – | Required. Used by the provisioning connection only. |
| `ddns_host` | `""` | DDNS hostname. Empty disables the DDNS updater. |
| `pihole_web_password` | `""` | Empty generates a random password, left in `/root/pihole-web-password`. |
| `pihole_upstream_dns` | `["1.1.1.1", "1.0.0.1"]` | Pi-hole upstream resolvers. |
| `pihole_dnssec` | `false` | Enable Pi-hole DNSSEC validation. |
| `wireguard_address` | `10.182.229.1/24` | Server tunnel address. |
| `wireguard_subnet` | `10.182.229.0/24` | Used for the NAT/MASQUERADE rule. |
| `wireguard_port` | `51820` | WireGuard UDP port. |
| `wireguard_mtu` | `1280` | 1280 avoids fragmentation on mobile clients. |
| `wireguard_clients` | `[]` | Peers to generate. See below. |
| `ddns_install_oci_cli` | `true` | Install the OCI CLI in a venv on the instance. |
| `reboot_after_setup` | `true` | Reboot once provisioning finishes. |

`wireguard_clients` entries take `name`, `ip`, and an optional `allowed_ips`.
Keypairs and preshared keys are generated **on the instance**, so the private
keys never pass through Terraform:

```hcl
wireguard_clients = [
  { name = "laptop", ip = "10.182.229.2" },                                  # full tunnel
  { name = "phone-dns", ip = "10.182.229.3", allowed_ips = "10.182.229.1/32" }, # DNS only
]
```

## Deployment

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Or with the Makefile: `make init`, `make plan`, `make apply`.

## After the apply

- **The instance reboots** roughly two minutes after provisioning ends, because
  `setup.py` installs kernel updates last. Set `reboot_after_setup = false` to skip.
- **Pi-hole admin UI**: `https://<public_ip>/admin` (self-signed certificate).
  Use `pihole_web_password`, or read the generated one with
  `ssh ubuntu@<ip> "sudo cat /root/pihole-web-password"`.
- **WireGuard client configs** live on the server at
  `/etc/wireguard/configs/<name>.conf`, mode 600:

  ```bash
  ssh ubuntu@<public_ip> "sudo cat /etc/wireguard/configs/laptop.conf"
  ```

- Useful outputs: `public_ip`, `ssh_command`, `ddns_security_list_id`,
  `availability_domain` (`terraform output`).

### DDNS credentials (manual, by design)

The DDNS job rewrites the `source` of every ingress rule in the DDNS-managed
security list to your current home IP. That is what keeps SSH, DNS and the admin
UI reachable when your ISP changes your address. It needs an OCI API key, which
must not live in git, so this step is manual:

1. Create an API key for your IAM user (console, or
   `oci iam user api-key upload --user-id <ocid> --key-file <public.pem>`).
2. Copy the private key to the instance and configure the CLI for user `ubuntu`:
   `scp <private_key>.pem ubuntu@<public_ip>:~/.oci/`, then add `key_file` to
   `~/.oci/config` on the instance.
3. If the key has a pass phrase, store it root-only — this is where the updater
   reads it:
   `echo '<passphrase>' | sudo tee /etc/oci/oci_api_key_passphrase && sudo chmod 600 /etc/oci/oci_api_key_passphrase`

   Note: `sudo -u ubuntu` resets `HOME` and breaks the CLI; log in as `ubuntu`
   directly instead.
4. Verify without changing anything:

   ```bash
   ssh ubuntu@<public_ip> "cd ~/bin/oci-cli-scripts && python3 update_ddns.py \
     --host <ddns_host> \
     --security-list-ocid $(terraform output -raw ddns_security_list_id) \
     --dry-run"
   ```

Until this is done the instance still works, but the security list will not
follow a home IP change. A freshly uploaded OCI API key can also return
`401 NotAuthenticated` for several minutes before it becomes active.

## Cutting over from an existing Pi-hole

- **The new instance gets a new reserved public IP.** Every WireGuard client's
  `Endpoint` and every device pointed at the old address must be updated.
- **Client keypairs are regenerated**, so each client needs its new
  `/etc/wireguard/configs/<name>.conf`; preshared keys change too.
- **Pi-hole data is not migrated.** Blocklists, local DNS records and the
  allowlist are installed fresh. Export them from the old server first
  (`pihole-FTL` database or the Teleporter in the v6 web UI) if you want them.
- Re-point DHCP/DNS clients only after the new server resolves correctly, then
  decommission the old VM.

## Security notes

- SSH is **not** exposed to the world: it is allowed only from `allowed_ip` and
  the home IP is refreshed by the DDNS job.
- WireGuard `51820/udp` is world-open by necessity; every peer requires a
  preshared key.
- fail2ban bans repeated SSH authentication failures for a week (`recidive`).
- `/etc/wireguard/wg0.conf` and the generated client configs are root-only (`600`).
- Two earlier problems are fixed here: `tcp/22` used to be open to `0.0.0.0/0`,
  and the DDNS list opened the entire `53–443` range instead of just 53 and 443.

## Known limitations

- **State is local and gitignored.** `terraform/terraform.tfstate` is the only
  record of what exists — back it up, or configure a remote backend, before you
  rely on it. An earlier run of this repository lost its state and had to be
  inventoried from scratch.
- Pi-hole configuration (blocklists, local DNS records, users) is not managed by
  Terraform after installation.
- The provisioner connects over SSH to the instance's public IP, so run `apply`
  from home or over the tunnel.

## License

MIT
