# Pi-hole and WireGuard on OCI

Infrastructure as Code for a Pi-hole v6 DNS server with a PiVPN-managed
WireGuard VPN on an Oracle Cloud Infrastructure Always Free
`VM.Standard.E2.1.Micro` instance.

Terraform builds the network (VCN, subnet, internet gateway, route table, a
reserved public IP) and the instance. `scripts/setup.py` then provisions the
server over SSH: Pi-hole v6, PiVPN (WireGuard mode) plus its initial clients,
fail2ban, a weekly reboot check, and optionally a DDNS job that keeps the
security list pointed at your home IP.

## Repository layout

| Path | Purpose |
| --- | --- |
| `terraform/` | Terraform root module. Run Terraform from this directory. |
| `scripts/setup.py` | Provisioning entry point, executed on the instance by `null_resource.setup_provisioner`. |
| `scripts/conf/` | Files copied to the instance (the DDNS updater and the reboot check). |
| `Taskfile.yml` | Convenience wrappers around the Terraform commands ([Task](https://taskfile.dev)). |
| `.github/workflows/` | CI: `terraform fmt`/`validate` plus provisioning-script syntax checks. |
| `LICENSE` | MIT. |

## Prerequisites

1. An OCI tenancy where you can create networking and compute resources.
2. [Terraform](https://developer.hashicorp.com/terraform/install) **1.5 or newer**
   (`terraform/provider.tf` enforces `required_version = ">= 1.5"`).
3. OCI API credentials in `~/.oci/config`. The Terraform provider reads these
   directly; the OCI CLI itself is only needed for the DDNS credentials step below.
4. An SSH keypair for the instance.
5. Optional: a DDNS hostname (for example an Asus router's `asuscomm.com` name).
   Required if you want the security list to follow a changing home IP.
6. Optional: [Task](https://taskfile.dev/installation) for the shortcut commands
   below. Run `task --list` to see everything it provides.

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
| `wireguard_clients` | `[]` | **Initial** PiVPN clients. See below. |
| `pivpn_version` | `v4.11.1` | PiVPN release to install (pinned git tag). |
| `ddns_install_oci_cli` | `true` | Install the OCI CLI in a venv on the instance. |
| `reboot_after_setup` | `true` | Reboot once provisioning finishes. |

`wireguard_clients` entries take `name` and `ip`. They are created once with
`pivpn add`, and only when they are not already peers, so a re-apply never
overwrites a key that is in use:

```hcl
wireguard_clients = [
  { name = "laptop", ip = "10.182.229.2" },
  { name = "phone", ip = "10.182.229.3" },
]
```

## Deployment

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Or with Task: `task init`, `task plan`, `task apply`. Run `task --list` to see
all of the available shortcuts.

## After the apply

- **The instance reboots** roughly two minutes after provisioning ends, because
  `setup.py` installs kernel updates last. Set `reboot_after_setup = false` to skip.
- **Pi-hole admin UI**: `https://<public_ip>/admin` (self-signed certificate).
  Use `pihole_web_password`, or read the generated one with
  `ssh ubuntu@<ip> "sudo cat /root/pihole-web-password"`.
- **WireGuard is managed by PiVPN, not by Terraform.** Configs live in
  `/etc/wireguard/configs/` and peers are added and removed on the instance:

  | Task | Command |
  | --- | --- |
  | Add a client | `sudo pivpn add` (prompts) or `sudo pivpn add -n laptop -ip 10.182.229.4` |
  | Show a QR code | `pivpn -qr laptop` |
  | List clients / connected peers | `pivpn -l` / `pivpn -c` |
  | Remove / disable / enable | `pivpn -r laptop` / `pivpn -off laptop` / `pivpn -on laptop` |

  Fetch a config with
  `ssh ubuntu@<public_ip> "sudo cat /etc/wireguard/configs/laptop.conf"`.

  PiVPN is pinned to the `var.pivpn_version` git tag under
  `/usr/local/src/pivpn`, so `pivpn -up` is not expected to work — a detached
  HEAD cannot `git pull`. Bump `pivpn_version` and re-apply instead, or run
  `git -C /usr/local/src/pivpn checkout master` on the box first.

- Useful outputs: `public_ip`, `private_ip`, `instance_id`, `ssh_command`,
  `ddns_security_list_id`, `availability_domain` (`terraform output`).

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
- PiVPN writes `/etc/wireguard/wg0.conf` and `/etc/wireguard/configs/*` as
  `root:root` mode `644` (PiVPN's own default, and what the old server has).
  The client configs contain private keys, so on a shared box tighten them with
  `chmod 600 /etc/wireguard/configs/*.conf`; PiVPN does not reset that when a
  peer is added.
- Two earlier problems are fixed here: `tcp/22` used to be open to `0.0.0.0/0`,
  and the DDNS list opened the entire `53–443` range instead of just 53 and 443.

## Known limitations

- **State is local and gitignored, by design.** This is a single-operator
  project, so there is no shared or locked backend to configure — Terraform
  keeps state in `terraform/terraform.tfstate` on your machine. That file is the
  only record of what exists, so **copy it somewhere safe after each apply**
  (`task backup-state` snapshots it to `terraform/backups/`). If
  you lose it, re-applying builds a *second* stack instead of reconciling the
  existing one; an earlier run of this repository hit exactly that and had to be
  inventoried by hand. If you want off-box state history, the
  [OCI Object Storage backend](https://developer.hashicorp.com/terraform/language/backend/oci)
  is one option — a commented example lives in `terraform/provider.tf`.
- Pi-hole configuration (blocklists, local DNS records, users) is not managed by
  Terraform after installation.
- WireGuard peer state lives in PiVPN on the instance (`wg0.conf` plus
  `/etc/wireguard/configs/`). A rebuilt instance recreates only the clients
  listed in `wireguard_clients`, so anything added later with `pivpn add` has to
  be re-added — keep that list up to date if you want a rebuild to restore them.
- The provisioner connects over SSH to the instance's public IP, so run `apply`
  from home or over the tunnel.

## License

MIT
