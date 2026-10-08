#!/usr/bin/env python3
"""
Update OCI security list ingress rules to the current IP of a DDNS host.

This is a Python rewrite of the shell script:
  ubuntu/bin/oci-cli-scripts/update_ddns.sh

Behavior:
 - Resolves the configured DDNS hostname (prefers IPv4).
 - Fetches the security list with the OCI CLI.
 - If all ingress rules already have the resolved IP/32 as their `source`,
   no update is performed.
 - Otherwise, replaces every ingress rule's `source` with the new CIDR
   and updates the security list via the OCI CLI.

Note:
 - This script shells out to the OCI CLI. Ensure the OCI CLI is installed
   and configured for the target compartment/tenancy.
 - The API key pass phrase is not stored in ~/.oci/config. It is read at
   runtime from a root-only file (see --passphrase-file) via sudo, or taken
   from OCI_CLI_PASSPHRASE if that is already set.
 - The deployment-specific defaults (DEFAULT_DDNS_HOST and
   DEFAULT_SECURITY_LIST_OCID) are deliberately blank; the cron entry written
   by scripts/setup.py always passes --host and --security-list-ocid
   explicitly. Other defaults can be overridden via command line flags.

Example:
  python3 update_ddns.py --host example.ddns.net \
                         --security-list-ocid ocid1.securitylist... \
                         --region eu-stockholm-1

"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
from datetime import datetime
from ipaddress import IPv4Address, ip_address
from shutil import which
from typing import Optional, Tuple

# These two are deployment-specific and deliberately blank: a stale security
# list OCID would silently rewrite the source of the wrong security list. The
# cron entry written by scripts/setup.py always passes both explicitly.
DEFAULT_DDNS_HOST = ""
DEFAULT_SECURITY_LIST_OCID = ""
DEFAULT_REGION = "eu-stockholm-1"
DEFAULT_OCI_CLI_PATH = "/home/ubuntu/bin/oci"  # matches the existing environment
# The API key pass phrase lives in a root-only file (not in ~/.oci/config) and
# is read at runtime, then handed to the OCI CLI via OCI_CLI_PASSPHRASE.
DEFAULT_PASSPHRASE_FILE = "/etc/oci/oci_api_key_passphrase"


def now() -> str:
    return datetime.now().isoformat(sep=" ", timespec="seconds")


def resolve_host_ipv4(host: str) -> Optional[str]:
    """
    Resolve the host and prefer IPv4 addresses. Returns the IP string or None on failure.
    """
    try:
        # Use getaddrinfo to inspect address families, prefer AF_INET
        infos = socket.getaddrinfo(host, None)
        for info in infos:
            family = info[0]
            sockaddr = info[4]
            if family == socket.AF_INET:
                ip_address = sockaddr[0]
                return str(ip_address)
        # Fallback to gethostbyname (IPv4) which may still succeed
        return socket.gethostbyname(host)
    except Exception as exc:  # broad on purpose to mirror original script behavior
        print(
            f"{now()}: ERROR: Could not resolve DDNS hostname: {host} ({exc})",
            file=sys.stderr,
        )
        return None


def load_passphrase(path: str) -> Optional[str]:
    """
    Load the OCI API key pass phrase at runtime.

    Precedence:
      1. OCI_CLI_PASSPHRASE already set in the environment (e.g. a systemd
         credential or a manual export).
      2. The file at `path`, read directly when the current user can read it.
      3. The file at `path`, read via non-interactive sudo (root-only file).

    Returns the pass phrase, or None if it could not be read.
    """
    env_value = os.environ.get("OCI_CLI_PASSPHRASE")
    if env_value:
        return env_value

    if os.access(path, os.R_OK):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                value = fh.read().strip()
            if value:
                return value
        except OSError as exc:
            print(
                f"{now()}: WARNING: Could not read pass phrase file {path}: {exc}",
                file=sys.stderr,
            )

    try:
        proc = subprocess.run(
            ["sudo", "-n", "cat", path], capture_output=True, text=True
        )
    except FileNotFoundError:
        print(
            f"{now()}: ERROR: sudo not found; cannot read pass phrase from {path}",
            file=sys.stderr,
        )
        return None

    if proc.returncode != 0:
        print(
            f"{now()}: ERROR: Could not read pass phrase via sudo from {path}: "
            f"{proc.stderr.strip()}",
            file=sys.stderr,
        )
        return None

    value = proc.stdout.strip()
    return value or None


def run_oci(
    oci_path: str,
    args: list[str],
    region: str,
    passphrase: Optional[str] = None,
    capture_stderr: bool = True,
) -> Tuple[int, str, str]:
    """
    Run OCI CLI with provided args and region. Returns (returncode, stdout, stderr).

    The API key pass phrase is passed to the CLI through the OCI_CLI_PASSPHRASE
    environment variable rather than being stored in the config file.
    """
    cmd = [oci_path] + args + ["--region", region]
    env = os.environ.copy()
    if passphrase:
        env["OCI_CLI_PASSPHRASE"] = passphrase
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", f"OCI CLI not found at {oci_path}"
    except Exception as exc:
        return 1, "", str(exc)


def validate_ipv4(ip_str: str) -> bool:
    try:
        ip = ip_address(ip_str)
        return isinstance(ip, IPv4Address)
    except Exception:
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Update OCI security list ingress rules to current DDNS IP"
    )
    parser.add_argument(
        "--host", default=DEFAULT_DDNS_HOST, help="DDNS hostname to resolve"
    )
    parser.add_argument(
        "--security-list-ocid",
        default=DEFAULT_SECURITY_LIST_OCID,
        help="Security List OCID to update",
    )
    parser.add_argument("--region", default=DEFAULT_REGION, help="OCI region")
    parser.add_argument(
        "--oci-cli-path",
        default=DEFAULT_OCI_CLI_PATH,
        help="Path to the OCI CLI binary (default: %(default)s)",
    )
    parser.add_argument(
        "--passphrase-file",
        default=DEFAULT_PASSPHRASE_FILE,
        help="Root-only file holding the API key pass phrase (default: %(default)s)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done but do not call update",
    )
    args = parser.parse_args(argv)

    host = args.host
    sl_ocid = args.security_list_ocid
    region = args.region
    oci_path = args.oci_cli_path
    passphrase_file = args.passphrase_file
    dry_run = args.dry_run

    if not host:
        print(
            f"{now()}: ERROR: No DDNS hostname given. Pass --host or set DEFAULT_DDNS_HOST.",
            file=sys.stderr,
        )
        return 1

    if not sl_ocid:
        print(
            f"{now()}: ERROR: No security list OCID given. Pass --security-list-ocid "
            "(see `terraform output ddns_security_list_id`).",
            file=sys.stderr,
        )
        return 1

    passphrase = load_passphrase(passphrase_file)
    if passphrase is None:
        print(
            f"{now()}: ERROR: Could not load API key pass phrase from {passphrase_file}. "
            "Set OCI_CLI_PASSPHRASE or ensure the file is readable (via sudo).",
            file=sys.stderr,
        )
        return 1

    # If the provided oci_path is not executable, try to discover it in PATH
    if which(oci_path) is None:
        discovered = which("oci")
        if discovered:
            oci_path = discovered
        # else keep provided path; run_oci will error if it's missing

    current_ip = resolve_host_ipv4(host)
    if not current_ip:
        # resolve_host_ipv4 already logged the error
        return 1

    if not validate_ipv4(current_ip):
        print(
            f"{now()}: ERROR: Resolved address is not a valid IPv4 address: {current_ip}",
            file=sys.stderr,
        )
        return 1

    new_cidr = f"{current_ip}/32"

    print("-----")
    print(f"{now()}: Fetching existing rules for Security List...")

    rc, out, err = run_oci(
        oci_path,
        ["network", "security-list", "get", "--security-list-id", sl_ocid],
        region,
        passphrase,
    )
    if rc != 0:
        print(
            f"{now()}: ERROR: Failed to fetch Security List data. rc={rc} stderr={err}",
            file=sys.stderr,
        )
        return 1

    try:
        sec = json.loads(out)
    except Exception as exc:
        print(
            f"{now()}: ERROR: Failed to parse OCI CLI output as JSON: {exc}",
            file=sys.stderr,
        )
        return 1

    data = sec.get("data", {})
    ingress_rules = data.get("ingress-security-rules", [])
    egress_rules = data.get("egress-security-rules", [])

    total_count = len(ingress_rules)
    match_count = sum(1 for r in ingress_rules if r.get("source") == new_cidr)

    if total_count == 0:
        # No ingress rules to update; keep behavior sensible (warn + exit 0)
        print(
            f"{now()}: WARNING: No ingress rules found in security list {sl_ocid}. Nothing to update."
        )
        return 0

    if match_count == total_count:
        print(
            f"{now()}: All ingress rules already set to {new_cidr}. No update needed."
        )
        return 0

    # Construct updated ingress rules: replace 'source' on each rule
    updated_ingress = []
    for rule in ingress_rules:
        new_rule = dict(rule)  # shallow copy
        new_rule["source"] = new_cidr
        updated_ingress.append(new_rule)

    ingress_json = json.dumps(updated_ingress)
    egress_json = json.dumps(egress_rules)

    print(f"{now()}: Updating {total_count} ingress rule(s) to {new_cidr}...")

    if dry_run:
        print(
            f"{now()}: DRY RUN - would call OCI CLI update with:\n  --ingress-security-rules {ingress_json}\n  --egress-security-rules {egress_json}"
        )
        return 0

    rc2, out2, err2 = run_oci(
        oci_path,
        [
            "network",
            "security-list",
            "update",
            "--security-list-id",
            sl_ocid,
            "--ingress-security-rules",
            ingress_json,
            "--egress-security-rules",
            egress_json,
            "--force",
        ],
        region,
        passphrase,
    )

    if rc2 == 0:
        print(f"{now()}: SUCCESS: All ingress rules updated to {new_cidr}.")
        return 0
    else:
        print(
            f"{now()}: FAILURE: OCI CLI command failed to update Security List. rc={rc2} stderr={err2}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
