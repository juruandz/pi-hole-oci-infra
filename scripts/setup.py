#!/usr/bin/env python3
"""
Provisioning script for the Pi-hole server instance.

Runs non-interactive apt upgrades, installs required packages,
creates /usr/local/bin/nightly_reboot_check.sh, configures cron,
creates logs, configures iptables, and schedules a reboot.
"""

import os
import sys
import subprocess
import logging
from pathlib import Path

LOG = logging.getLogger("setup")


def run(cmd, check=True):
    LOG.info("Running: %s", cmd)
    return subprocess.run(cmd, check=check)


def ensure_package_installed(pkgs):
    run(['apt-get', 'install', '-y'] + pkgs)


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
        ensure_package_installed(['curl', 'git', 'dos2unix'])

        # Create maintenance scripts directory
        Path('/usr/local/bin').mkdir(parents=True, exist_ok=True)

        # Create reboot check script (kept as bash)
        reboot_script = Path('/usr/local/bin/nightly_reboot_check.sh')
        reboot_content = r"""#!/bin/bash
# Script to check for a required reboot and perform it.
LOGFILE="/var/log/nightly_reboot.log"

echo "--- $(date) - Starting weekly reboot check ---" >> $LOGFILE

# Check for /var/run/reboot-required file (standard update check)
if [ -f /var/run/reboot-required ]; then
    echo "$(date) - Reboot required based on /var/run/reboot-required." >> $LOGFILE
    REBOOT_NEEDED=1
else
    # Check using needrestart for kernel/critical library updates
    # The 'needrestart' utility exits with a status code of 3 if a restart is needed.
    # -r i: Check for kernel reboot only (not service restarts) and use interactive/informational mode
    if needrestart -r i | grep -q "System is asking for a reboot"; then
        echo "$(date) - Reboot required based on needrestart output (kernel/library update)." >> $LOGFILE
        REBOOT_NEEDED=1
    else
        echo "$(date) - No reboot required." >> $LOGFILE
        REBOOT_NEEDED=0
    fi
fi

# Perform reboot if needed
if [ "$REBOOT_NEEDED" -eq 1 ]; then
    echo "$(date) - Scheduling reboot in 5 minutes." >> $LOGFILE
    # /sbin/shutdown -r +5 schedules a reboot in 5 minutes with a warning message
    /sbin/shutdown -r +5 "Automated nightly reboot due to system updates." >> $LOGFILE 2>&1
    echo "$(date) - Reboot command executed." >> $LOGFILE
fi

echo "--- $(date) - Nightly reboot check finished ---" >> $LOGFILE
"""
        reboot_script.write_text(reboot_content)
        os.chmod(reboot_script, 0o755)

        # Install required packages for scripts
        # iptables-persistent provides /etc/iptables/ and netfilter-persistent
        ensure_package_installed(['needrestart', 'jq', 'dnsutils', 'iptables-persistent'])

        # Set up cron jobs (run as root since shutdown requires root permissions)
        cron_line = "0 3 * * 6 /usr/local/bin/nightly_reboot_check.sh"
        p = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
        existing = p.stdout if p.returncode == 0 else ''
        lines = [l for l in existing.splitlines() if l.strip() != '']
        if cron_line not in lines:
            lines.append(cron_line)
            seen = set()
            new_lines = []
            for l in lines:
                if l not in seen:
                    seen.add(l)
                    new_lines.append(l)
            new_cron = "\n".join(new_lines) + "\n"
            subprocess.run(['crontab', '-'], input=new_cron, text=True, check=True)

        # Create log files with proper permissions
        log_path = Path('/var/log/nightly_reboot.log')
        log_path.touch(exist_ok=True)
        os.chmod(str(log_path), 0o644)

        # Configure iptables rules idempotently
        rules = [
            ['iptables', '-C', 'INPUT', '-p', 'udp', '-m', 'udp', '--dport', '53', '-j', 'ACCEPT'],
            ['iptables', '-C', 'INPUT', '-p', 'tcp', '-m', 'tcp', '--dport', '53', '-j', 'ACCEPT'],
            ['iptables', '-C', 'INPUT', '-p', 'tcp', '-m', 'state', '--state', 'NEW', '-m', 'tcp', '--dport', '80', '-j', 'ACCEPT'],
            ['iptables', '-C', 'INPUT', '-p', 'tcp', '-m', 'state', '--state', 'NEW', '-m', 'tcp', '--dport', '443', '-j', 'ACCEPT'],
        ]
        for check_cmd in rules:
            res = subprocess.run(check_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if res.returncode != 0:
                add_cmd = check_cmd.copy()
                add_cmd[1] = '-A'
                run(add_cmd)

        # Persist rules so they survive the reboot scheduled below
        run(['netfilter-persistent', 'save'])
        run(['systemctl', 'enable', 'netfilter-persistent'])

        # Save configuration info
        ip_proc = subprocess.run(['curl', '-s', 'ifconfig.me'], capture_output=True, text=True)
        LOG.info("=== Server Configuration ===")
        LOG.info("Server IP: %s", ip_proc.stdout.strip())
        LOG.info("Setup completed successfully!")

        # Schedule reboot
        run(['/sbin/shutdown', '-r', '+2', 'Scheduled reboot after setup'])

    except subprocess.CalledProcessError as e:
        LOG.exception("Command failed: %s", e)
        sys.exit(1)
    except Exception as ex:
        LOG.exception("Unexpected error: %s", ex)
        sys.exit(1)


if __name__ == '__main__':
    main()
