#!/bin/bash
set -eu

# Set environment variables to suppress interactive prompts
export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFNEW=1

# Function to log and exit on error
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

trap 'error_exit "Script failed at line $LINENO"' ERR

# Update system with non-interactive options
apt-get update || error_exit "Failed to update apt cache"
NEEDRESTART_MODE=a apt-get upgrade -y || error_exit "Failed to upgrade packages"

# Install required packages
NEEDRESTART_MODE=a apt-get install -y curl git dos2unix || error_exit "Failed to install required packages"

# Create maintenance scripts directory
mkdir -p /usr/local/bin || error_exit "Failed to create /usr/local/bin directory"

# Create reboot check script
cat > /usr/local/bin/nightly_reboot_check.sh << 'EOF'
#!/bin/bash
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
EOF

# Make scripts executable
chmod +x /usr/local/bin/nightly_reboot_check.sh || error_exit "Failed to make nightly_reboot_check.sh executable"

# Install required packages for scripts
NEEDRESTART_MODE=a apt-get install -y needrestart jq dnsutils || error_exit "Failed to install script dependencies"

# Set up cron jobs (run as root since shutdown requires root permissions)
sudo bash -c 'crontab -l 2>/dev/null; echo "0 3 * * 6 /usr/local/bin/nightly_reboot_check.sh"' | sort -u | sudo crontab -

# Create log files with proper permissions
sudo touch /var/log/nightly_reboot.log
sudo chmod 644 /var/log/nightly_reboot.log

# Save configuration info
echo "=== Server Configuration ==="
echo "Server IP: $(curl -s ifconfig.me)"
echo "Setup completed successfully!"