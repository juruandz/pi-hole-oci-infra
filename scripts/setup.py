#!/usr/bin/env python3
"""Provision the Pi-hole + WireGuard server.

Invoked over SSH by ``null_resource.setup_provisioner``. All deployment
settings arrive in ``/tmp/provision-vars.json``, which Terraform renders with
``jsonencode()``, so nothing secret is stored in the repository.

Every stage is idempotent: re-running this script (for example after an edit,
which flips the ``null_resource`` trigger) must not damage a working server.

Stages:
  1. apt update/upgrade and base packages
  2. Pi-hole v6 unattended install
  3. WireGuard server and generated client configs
  4. fail2ban
  5. firewall rules and persistence
  6. maintenance script and cron entries
  7. DDNS security-list updater
  8. reboot if the updates require it

Deliberately not automated, because it needs secrets that must not live in
git: the OCI API key and its pass phrase used by the DDNS updater. See the
"DDNS credentials" section of README.md.
"""

import json
import logging
import os
import secrets
import string
import subprocess
import sys
from ipaddress import ip_interface, ip_network
from pathlib import Path
from typing import Any

LOG = logging.getLogger("setup")

VARS_PATH = Path("/tmp/provision-vars.json")
UBUNTU_HOME = Path("/home/ubuntu")
DDNS_DIR = UBUNTU_HOME / "bin" / "oci-cli-scripts"
WG_DIR = Path("/etc/wireguard")
OCI_CLI_VENV = UBUNTU_HOME / "lib" / "oracle-cli"
PASSPHRASE_FILE = Path("/etc/oci/oci_api_key_passphrase")


def _describe(cmd, redact: bool) -> str:
    """Render a command for the log, optionally hiding its final argument.

    Provisioning output lands in terraform's apply output and any CI log, so
    commands carrying a secret (the Pi-hole password) must not print it.
    """
    parts = [str(part) for part in cmd]
    if redact and parts:
        parts[-1] = '<redacted>'
    return " ".join(parts)


def run(cmd, check=True, redact=False, **kwargs):
    LOG.info("Running: %s", _describe(cmd, redact))
    return subprocess.run(cmd, check=check, **kwargs)


def run_ok(cmd, redact=False, **kwargs) -> bool:
    """Run a command and report whether it exited 0, discarding its output.

    Used for the "does this rule/file already exist" probes and for optional
    commands whose failure must not abort provisioning.
    """
    LOG.info("Checking: %s", _describe(cmd, redact))
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kwargs
        )
    except FileNotFoundError:
        return False
    return proc.returncode == 0


def capture(cmd) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()


def ensure_package_installed(pkgs, recommends=True):
    cmd = ['apt-get', 'install', '-y']
    if not recommends:
        # python3-pip Recommends build-essential, which drags in gcc/g++ and
        # friends: a compiler toolchain is useless on a 1 GB instance and costs
        # several minutes of install time.
        cmd.append('--no-install-recommends')
    run(cmd + pkgs)


def write_file(path: Path, content: str, mode: int, owner: str | None = None) -> None:
    """Write ``content`` to ``path``, creating parents, then set mode/owner."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    os.chmod(path, mode)
    if owner:
        run(['chown', owner, str(path)])


def load_vars() -> dict[str, Any]:
    if not VARS_PATH.exists():
        LOG.error("Missing %s; nothing to provision.", VARS_PATH)
        sys.exit(1)
    with VARS_PATH.open(encoding="utf-8") as fh:
        return json.load(fh)


def default_interface() -> str:
    """Name of the interface carrying the default route (``ens3`` on OCI)."""
    return capture(
        ["sh", "-c", "ip -o -4 route show default | awk '{print $5}' | head -n1"]
    )


def generate_password(length: int = 24) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def update_crontab(user: str, wanted: list[str], drop_substrings: list[str]) -> None:
    """Idempotently ensure ``wanted`` cron lines exist and stale ones are gone.

    Existing entries (including comments) are preserved; only lines containing
    one of ``drop_substrings`` are discarded.
    """
    proc = subprocess.run(
        ['crontab', '-u', user, '-l'], capture_output=True, text=True
    )
    existing = proc.stdout.splitlines() if proc.returncode == 0 else []

    kept = [
        line
        for line in existing
        if line.strip() and not any(s in line for s in drop_substrings)
    ]
    for line in wanted:
        if line not in kept:
            kept.append(line)

    subprocess.run(
        ['crontab', '-u', user, '-'],
        input="\n".join(kept) + "\n",
        text=True,
        check=True,
    )
    LOG.info("crontab for %s updated (%d entries)", user, len(kept))


def ensure_iptables_rule(body: list[str], table: str | None = None) -> None:
    """Put a rule at the top of its chain, replacing any existing copy.

    Insertion rather than append is essential: the stock OCI image ruleset ends
    its INPUT chain with a catch-all REJECT, so an appended rule sits after it
    and never matches anything.

    An existing copy is deleted first rather than left in place, because `-C`
    matches a rule wherever it sits -- a rule appended after the catch-all is
    present but inert, and skipping it would leave it inert forever.
    """
    prefix = ['iptables'] + (['-t', table] if table else [])
    for _ in range(5):
        if not run_ok(prefix + ['-C'] + body):
            break
        run(prefix + ['-D'] + body)
    run(prefix + ['-I', body[0], '1'] + body[1:])


# ---------------------------------------------------------------------------
# Stage 2: Pi-hole
# ---------------------------------------------------------------------------

def install_pihole(cfg: dict[str, Any], iface: str) -> None:
    """Install Pi-hole v6 and apply the configured settings.

    The v6 installer only runs without dialogs on its "not a fresh install"
    path. check_fresh_install() sets fresh_install=false as soon as
    /etc/pihole/pihole.toml (or the v5 setupVars.conf) exists, and every
    prompting function -- welcomeDialogs, chooseInterface, setDNS,
    chooseBlocklists, setPrivacyLevel -- sits inside the `fresh_install == true`
    branch. The --unattended flag is honoured only in the else branch, so
    pre-seeding pihole.toml is what makes an unattended install possible at all.

    Two consequences, both handled below:
      * the installer skips its own config-application block (also fresh-only),
        so upstreams/interface/privacy/DNSSEC are applied here through the v6
        CLI. Their defaults are empty (upstreams = []), so this is not optional;
      * the installer never sets our password (WEBPASSWORD is not a variable in
        v6 at all), so `pihole setpassword` is called here.
    """
    config_dir = Path('/etc/pihole')
    toml = config_dir / 'pihole.toml'

    already_installed = (
        run_ok(['pihole', '-v'])
        and run_ok(['systemctl', 'is-active', '--quiet', 'pihole-FTL'])
        and toml.exists()
        and toml.stat().st_size > 0
    )

    if already_installed:
        LOG.info("Pi-hole is installed and running; skipping the installer.")
    else:
        config_dir.mkdir(parents=True, exist_ok=True)
        if not toml.exists():
            # Empty marker: only its existence matters for the branch decision.
            toml.touch()

        installer = Path('/tmp/basic-install.sh')
        run(['curl', '-fsSL', 'https://install.pi-hole.net', '-o', str(installer)])

        env = os.environ.copy()
        env.update({
            'PIHOLE_INTERFACE': iface,
            'IPV4_ADDRESS': cfg["ipv4_address"],
            'IPV6_ADDRESS': '',
            'QUERY_LOGGING': 'true',
        })

        # stdin is deliberately /dev/null and there is a timeout: if a dialog
        # ever does get triggered it must fail fast rather than hang an apply
        # forever on a prompt that has no TTY to answer it.
        run(
            ['bash', str(installer), '--unattended'],
            env=env,
            stdin=subprocess.DEVNULL,
            timeout=1800,
        )

    # Applied on every run, so editing these tfvars values reconfigures an
    # existing installation instead of being ignored.
    set_ftl_config = ['pihole-FTL', '--config']
    run(set_ftl_config + ['dns.upstreams', json.dumps(list(cfg["upstream_dns"]))])
    run(set_ftl_config + ['dns.interface', iface])
    run(set_ftl_config + ['misc.privacylevel', '0'])
    run(set_ftl_config + ['dns.dnssec', 'true' if cfg["dnssec"] else 'false'])
    run(set_ftl_config + ['dns.queryLogging', 'true'])

    password = cfg["web_password"] or generate_password()
    if run_ok(['pihole', 'setpassword', password], redact=True):
        LOG.info("Pi-hole web password applied.")
    else:
        LOG.warning(
            "Could not set the Pi-hole web password; run `pihole setpassword` manually."
        )

    if not cfg["web_password"]:
        # Keep the generated password retrievable instead of discarding it.
        write_file(Path('/root/pihole-web-password'), password + "\n", 0o600)
        LOG.warning(
            "No pihole_web_password supplied; a generated one is stored in "
            "/root/pihole-web-password"
        )

    run(['systemctl', 'restart', 'pihole-FTL'])
    LOG.info("Pi-hole configured (upstreams=%s, interface=%s)", cfg["upstream_dns"], iface)


# ---------------------------------------------------------------------------
# Stage 3: WireGuard, managed by PiVPN
# ---------------------------------------------------------------------------

def _pivpn_config(cfg: dict[str, Any], iface: str) -> str:
    """Render the file PiVPN's --unattended mode sources.

    The variable names are PiVPN's own (it runs `source <file>` on this) and
    mirror /etc/pivpn/wireguard/setupVars.conf. Only inputs are set: the
    *_EDITED keys in that file are outputs the installer computes itself.
    """
    subnet = ip_network(cfg['subnet'], strict=False)
    address = ip_interface(cfg['address'])
    return "\n".join([
        'USING_UFW=0',
        'pivpnforceipv6route=1',
        f'IPv4dev={iface}',
        'install_user=ubuntu',
        'install_home=/home/ubuntu',
        'VPN=wireguard',
        f'pivpnPORT={cfg["port"]}',
        f'pivpnDNS1={address.ip}',
        'pivpnDNS2=',
        f'pivpnHOST={cfg["endpoint"]}',
        'pivpnPROTO=udp',
        f'pivpnMTU={cfg["mtu"]}',
        'pivpnDEV=wg0',
        f'pivpnNET={subnet.network_address}',
        f'subnetClass={subnet.prefixlen}',
        'pivpnenableipv6=0',
        'ALLOWED_IPS="0.0.0.0/0, ::0/0"',
        'UNATTUPG=1',
        '',
    ])


def install_pivpn(cfg: dict[str, Any], iface: str) -> None:
    """Install PiVPN (wireguard mode) unattended and create the initial peers.

    PiVPN owns wg0.conf, /etc/wireguard/configs, the 99-pivpn.conf sysctl file
    and the firewall's tunnel rules from here on. Peer management is `pivpn add`
    / `pivpn -qr` on the instance, deliberately not Terraform.

    The clients in var.wireguard_clients are created once, and only when they
    are not already peers, so a re-run never overwrites a key already in use.
    """
    source_dir = Path('/usr/local/src/pivpn')

    if (source_dir / 'auto_install' / 'install.sh').exists():
        LOG.info("PiVPN source already present in %s; skipping the clone.", source_dir)
    else:
        source_dir.parent.mkdir(parents=True, exist_ok=True)
        run(['git', 'clone', '--branch', cfg['version'],
             'https://github.com/pivpn/pivpn.git', str(source_dir)])

    config_file = Path('/tmp/pivpn.conf')
    write_file(config_file, _pivpn_config(cfg, iface), 0o600)

    # Migrate away from a wg0.conf that PiVPN did not write (an earlier version
    # of this script generated one). PiVPN must own that file; leaving both in
    # place means two managers overwriting each other on every run.
    wg0_conf = WG_DIR / 'wg0.conf'
    setup_vars = Path('/etc/pivpn/wireguard/setupVars.conf')
    if wg0_conf.exists() and not setup_vars.exists():
        backup = Path(str(wg0_conf) + '.pre-pivpn')
        wg0_conf.rename(backup)
        LOG.warning("Existing non-PiVPN wg0.conf moved aside to %s", backup)

    # PiVPN's unattended mode reports "no whiptail dialogs will be displayed".
    # stdin=/dev/null plus a timeout is the safety net: an unexpected prompt
    # fails fast rather than hanging an apply forever.
    run(
        ['bash', str(source_dir / 'auto_install' / 'install.sh'),
         '--unattended', str(config_file)],
        stdin=subprocess.DEVNULL,
        timeout=1800,
    )

    # Peers are identified by their marker in wg0.conf, not by the presence of a
    # client file: a leftover .conf from another manager holds a key that does
    # not match the current server key, so it has to be regenerated.
    configs_dir = WG_DIR / 'configs'
    existing_conf = wg0_conf.read_text() if wg0_conf.exists() else ''
    for client in cfg['clients']:
        name = client['name']
        if f"### begin {name} ###" in existing_conf:
            LOG.info("Client %s already a peer in wg0.conf; leaving it alone.", name)
            continue
        stale = configs_dir / f"{name}.conf"
        if stale.exists():
            LOG.warning("Removing stale client config %s before recreating it.", stale)
            stale.unlink()
        run(
            ['pivpn', 'add', '-n', name, '-ip', client['ip']],
            stdin=subprocess.DEVNULL,
            timeout=300,
        )

    LOG.info(
        "PiVPN %s installed (port %s); %d client config(s) ensured. Manage peers "
        "with `pivpn add` / `pivpn -qr`.",
        cfg['version'], cfg['port'], len(cfg['clients']),
    )


# ---------------------------------------------------------------------------
# Stage 4: fail2ban
# ---------------------------------------------------------------------------

def configure_fail2ban(ssh_port: int) -> None:
    jail_local = (
        "[recidive]\n"
        "enabled  = true\n"
        "logpath  = /var/log/fail2ban.log\n"
        "banaction = iptables-allports\n"
        "bantime  = 1w\n"
        "findtime = 1d\n"
        "maxretry = 5\n"
        "\n"
        "[sshd]\n"
        "enabled = true\n"
        f"port    = {ssh_port}\n"
        "logpath = %(sshd_log)s\n"
        "backend = %(sshd_backend)s\n"
    )
    write_file(Path('/etc/fail2ban/jail.local'), jail_local, 0o644)
    run(['systemctl', 'enable', 'fail2ban'])
    run(['systemctl', 'restart', 'fail2ban'])


# ---------------------------------------------------------------------------
# Stage 5: firewall
# ---------------------------------------------------------------------------

def configure_firewall(cfg: dict[str, Any], iface: str, ssh_port: int) -> None:
    """Open the ports this deployment serves, ahead of the image's default REJECT.

    The security list remains the access control: it restricts every one of these
    to the home IP. The host rules only decide what the instance accepts at all,
    which is what the stock REJECT would otherwise prevent.
    """
    for body in (
        ['INPUT', '-p', 'tcp', '--dport', str(ssh_port),
         '-m', 'comment', '--comment', 'ssh-input-rule', '-j', 'ACCEPT'],
        ['INPUT', '-i', iface, '-p', 'udp', '--dport', str(cfg['port']),
         '-m', 'comment', '--comment', 'wireguard-input-rule', '-j', 'ACCEPT'],
        ['INPUT', '-p', 'udp', '--dport', '53',
         '-m', 'comment', '--comment', 'pihole-dns-udp-rule', '-j', 'ACCEPT'],
        ['INPUT', '-p', 'tcp', '--dport', '53',
         '-m', 'comment', '--comment', 'pihole-dns-tcp-rule', '-j', 'ACCEPT'],
        ['INPUT', '-p', 'tcp', '--dport', '80',
         '-m', 'comment', '--comment', 'pihole-web-http-rule', '-j', 'ACCEPT'],
        ['INPUT', '-p', 'tcp', '--dport', '443',
         '-m', 'comment', '--comment', 'pihole-web-https-rule', '-j', 'ACCEPT'],
    ):
        ensure_iptables_rule(body)

    # Full-tunnel WireGuard clients need the tunnel subnet NATted out of ens3.
    ensure_iptables_rule(
        ['POSTROUTING', '-s', cfg['subnet'], '-o', iface,
         '-m', 'comment', '--comment', 'wireguard-nat-rule', '-j', 'MASQUERADE'],
        table='nat',
    )

    # Persist so the rules survive the reboot scheduled at the end of the run.
    run(['netfilter-persistent', 'save'])
    run(['systemctl', 'enable', 'netfilter-persistent'])


# ---------------------------------------------------------------------------
# Stage 6: maintenance
# ---------------------------------------------------------------------------

def install_maintenance() -> None:
    reboot_script = Path('/usr/local/bin/nightly_reboot_check.py')
    write_file(reboot_script, Path('/tmp/nightly_reboot_check.py').read_text(), 0o755)

    log_path = Path('/var/log/nightly_reboot.log')
    log_path.touch(exist_ok=True)
    os.chmod(str(log_path), 0o644)

    # Drop the legacy shell variant written by earlier versions of this script.
    update_crontab(
        'root',
        [f'0 3 * * 6 {reboot_script}'],
        drop_substrings=['nightly_reboot_check.sh'],
    )


# ---------------------------------------------------------------------------
# Stage 7: DDNS updater
# ---------------------------------------------------------------------------

def install_oci_cli() -> None:
    wrapper = UBUNTU_HOME / 'bin' / 'oci'
    if wrapper.exists():
        LOG.info("OCI CLI wrapper already present; skipping install.")
        return

    ensure_package_installed(['python3-venv', 'python3-pip'], recommends=False)
    run(['python3', '-m', 'venv', str(OCI_CLI_VENV)])
    run([str(OCI_CLI_VENV / 'bin' / 'pip'), 'install', '--quiet', '--upgrade', 'pip'])
    run([str(OCI_CLI_VENV / 'bin' / 'pip'), 'install', '--quiet', 'oci-cli'])
    run(['chown', '-R', 'ubuntu:ubuntu', str(OCI_CLI_VENV)])
    run(['chown', '-R', 'ubuntu:ubuntu', str(UBUNTU_HOME / 'lib')])

    write_file(
        wrapper,
        "#!"
        f"{OCI_CLI_VENV}/bin/python3\n"
        "import sys\n"
        "from oci_cli.cli import cli\n"
        "if __name__ == '__main__':\n"
        "    sys.exit(cli())\n",
        0o755,
        owner='ubuntu:ubuntu',
    )


def install_ddns(cfg: dict[str, Any]) -> None:
    if not cfg['enabled']:
        LOG.info(
            "DDNS updater disabled (need both ddns_host and a security list id); skipping."
        )
        return

    if cfg['install_oci_cli']:
        install_oci_cli()

    # Create the directory before chowning it; the updater runs as `ubuntu`.
    DDNS_DIR.mkdir(parents=True, exist_ok=True)
    run(['chown', '-R', 'ubuntu:ubuntu', str(DDNS_DIR.parent)])
    write_file(
        DDNS_DIR / 'update_ddns.py',
        Path('/tmp/update_ddns.py').read_text(),
        0o755,
        owner='ubuntu:ubuntu',
    )

    # /etc/oci holds the API key pass phrase (root-only, read via sudo -n).
    etc_oci = Path('/etc/oci')
    etc_oci.mkdir(parents=True, exist_ok=True)
    os.chmod(etc_oci, 0o700)

    log_path = Path('/var/log/ddns_update.log')
    log_path.touch(exist_ok=True)
    os.chmod(str(log_path), 0o664)
    run(['chown', 'ubuntu:ubuntu', str(log_path)])

    cron_line = (
        f"0 3 * * * python3 {DDNS_DIR / 'update_ddns.py'}"
        f" --host {cfg['host']}"
        f" --security-list-ocid {cfg['security_list_id']}"
        f" --region {cfg['region']}"
        f" >> {log_path} 2>&1"
    )
    update_crontab('ubuntu', [cron_line], drop_substrings=['update_ddns'])

    if not PASSPHRASE_FILE.exists():
        LOG.warning(
            "DDNS credentials are not in place yet. Upload the OCI API key to "
            "/home/ubuntu/.oci/ and the pass phrase to %s (root, mode 600); "
            "until then the security list will not follow your home IP. "
            "See README.md > DDNS credentials.",
            PASSPHRASE_FILE,
        )


def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s: %(message)s')
    os.environ.setdefault('DEBIAN_FRONTEND', 'noninteractive')
    os.environ.setdefault('UCF_FORCE_CONFNEW', '1')
    os.environ.setdefault('NEEDRESTART_MODE', 'a')

    try:
        # Update & upgrade
        run(['apt-get', 'update'])
        run(['apt-get', 'upgrade', '-y'])

        # Install basic packages
        ensure_package_installed(['curl', 'git'])

        # Install required packages for scripts
        # iptables-persistent provides /etc/iptables/ and netfilter-persistent
        ensure_package_installed([
            'needrestart', 'jq', 'dnsutils', 'iptables-persistent',
            'wireguard-tools', 'fail2ban',
        ])

        # Deployment settings rendered by Terraform (see provisioner.tf)
        cfg = load_vars()
        iface = default_interface()
        LOG.info("Using interface %s", iface)

        install_maintenance()
        install_pihole(cfg['pihole'], iface)
        install_pivpn(cfg['wireguard'], iface)
        configure_fail2ban(cfg['ssh_port'])
        configure_firewall(cfg['wireguard'], iface, cfg['ssh_port'])
        install_ddns(cfg['ddns'])

        # Save configuration info
        ip_proc = subprocess.run(['curl', '-s', 'ifconfig.me'], capture_output=True, text=True)
        LOG.info("=== Server Configuration ===")
        LOG.info("Server IP: %s", ip_proc.stdout.strip())
        LOG.info("Setup completed successfully!")

        # Schedule the reboot last: the upgrades above plus the freshly started
        # wg-quick@wg0 are best confirmed by a clean boot.
        if cfg['reboot_after_setup']:
            run(['/sbin/shutdown', '-r', '+2', 'Scheduled reboot after setup'])
        else:
            LOG.info("reboot_after_setup is false; skipping the final reboot.")

    except subprocess.CalledProcessError as e:
        LOG.exception("Command failed: %s", e)
        sys.exit(1)
    except Exception as ex:
        LOG.exception("Unexpected error: %s", ex)
        sys.exit(1)


if __name__ == '__main__':
    main()
