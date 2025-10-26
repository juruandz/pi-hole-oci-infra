#!/bin/bash
set -e

# Update system
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y curl git needrestart

# Run Pi-hole installation
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended

# Install PiVPN for easy WireGuard management
curl -L https://install.pivpn.io | bash

# Configure UFW if installed
if command -v ufw >/dev/null 2>&1; then
    ufw allow 51820/udp comment 'WireGuard VPN'
    ufw allow 53/tcp comment 'Pi-hole DNS TCP'
    ufw allow 53/udp comment 'Pi-hole DNS UDP'
    ufw allow 80/tcp comment 'Pi-hole Admin Interface'
fi

# Create maintenance scripts directory
mkdir -p /usr/local/bin
mkdir -p /home/ubuntu/bin/oci-cli-scripts

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
    needrestart -r i | grep -q "System is asking for a reboot"
    if [ $? -eq 0 ]; then
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

# Create DDNS update script
cat > /home/ubuntu/bin/oci-cli-scripts/update_ddns.sh << 'EOF'
#!/bin/bash

# --- CONFIGURATION ---
DDNS_HOST="DDNS_HOST_PLACEHOLDER"
# This will be replaced with the actual OCID by terraform
SECURITY_LIST_OCID="SECURITY_LIST_OCID_PLACEHOLDER"
REGION="REGION_PLACEHOLDER"
# --- END CONFIGURATION ---

CURRENT_IP=$(dig +short "$DDNS_HOST")
NEW_CIDR="${CURRENT_IP}/32"

if [ -z "$CURRENT_IP" ]; then
    echo "$(date): ERROR: Could not resolve DDNS hostname: $DDNS_HOST"
    exit 1
fi

echo "$(date): Fetching existing rules for Security List..."
SECURITY_LIST_JSON=$(/home/ubuntu/bin/oci network security-list get --security-list-id "$SECURITY_LIST_OCID" --region "$REGION")
if [ $? -ne 0 ]; then
    echo "$(date): ERROR: Failed to fetch Security List data."
    exit 1
fi

INGRESS_RULES=$(echo "$SECURITY_LIST_JSON" | jq -c '."data"."ingress-security-rules"')
EGRESS_RULES=$(echo "$SECURITY_LIST_JSON" | jq -c '."data"."egress-security-rules"')

# Compare all current CIDRs to the new one
MATCH_COUNT=$(echo "$INGRESS_RULES" | jq -r --arg NEW_CIDR "$NEW_CIDR" '[.[] | select(.source == $NEW_CIDR)] | length')
TOTAL_COUNT=$(echo "$INGRESS_RULES" | jq -r 'length')

if [ "$MATCH_COUNT" -eq "$TOTAL_COUNT" ]; then
    echo "$(date): All ingress rules already set to $NEW_CIDR. No update needed."
    exit 0
fi

# Update all rules to new CIDR
UPDATED_INGRESS_RULES=$(echo "$INGRESS_RULES" | jq -c --arg NEW_CIDR "$NEW_CIDR" 'map(.source = $NEW_CIDR)')

/home/ubuntu/bin/oci network security-list update \
    --security-list-id "$SECURITY_LIST_OCID" \
    --ingress-security-rules "$UPDATED_INGRESS_RULES" \
    --egress-security-rules "$EGRESS_RULES" \
    --region "$REGION" \
    --force > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "$(date): SUCCESS: All ingress rules updated to $NEW_CIDR."
else
    echo "$(date): FAILURE: OCI CLI command failed to update Security List."
    exit 1
fi
EOF

# Make scripts executable
chmod +x /usr/local/bin/nightly_reboot_check.sh
chmod +x /home/ubuntu/bin/oci-cli-scripts/update_ddns.sh

# Install required packages for scripts
apt-get install -y needrestart jq dnsutils

# Set up cron jobs
(crontab -l 2>/dev/null; echo "0 3 * * 6 /usr/local/bin/nightly_reboot_check.sh") | sort - | uniq - | crontab -
(sudo crontab -l 2>/dev/null; echo "0 3 * * * /home/ubuntu/bin/oci-cli-scripts/update_ddns.sh >> /var/log/ddns_update.log 2>&1") | sort - | uniq - | sudo crontab -

# Create log files with proper permissions
touch /var/log/nightly_reboot.log
touch /var/log/ddns_update.log
chmod 644 /var/log/nightly_reboot.log /var/log/ddns_update.log

# Save configuration info
echo "=== Server Configuration ==="
echo "Server IP: $(curl -s ifconfig.me)"
echo "Pi-hole Admin URL: http://$(curl -s ifconfig.me)/admin"
echo "PiVPN Status: $(pivpn status)"
echo "To add VPN clients, use: pivpn add"
echo "To list VPN clients, use: pivpn list"
echo "Setup completed successfully!"