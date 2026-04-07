#!/bin/bash
# Install the WiFi watchdog on the Raspberry Pi.
# Run as: bash setup_wifi_watchdog.sh

set -e

SCRIPT_SRC="$(dirname "$0")/wifi_watchdog.sh"
SCRIPT_DST="/usr/local/bin/wifi_watchdog.sh"
IFACE="${1:-wlan0}"

echo "=== WiFi Watchdog Setup ==="
echo "  Interface: $IFACE"
echo ""

# 1. Install the watchdog script
sudo cp "$SCRIPT_SRC" "$SCRIPT_DST"
sudo chmod +x "$SCRIPT_DST"
echo "Installed: $SCRIPT_DST"

# 2. Grant passwordless sudo for the specific commands needed
SUDOERS_FILE="/etc/sudoers.d/wifi-watchdog"
cat <<SUDOERS | sudo tee "$SUDOERS_FILE" > /dev/null
# Allow wifi_watchdog.sh to toggle wlan0 and restart network services
${USER} ALL=(ALL) NOPASSWD: /usr/sbin/ip link set ${IFACE} down
${USER} ALL=(ALL) NOPASSWD: /usr/sbin/ip link set ${IFACE} up
${USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart dhcpcd
${USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart NetworkManager
SUDOERS
sudo chmod 440 "$SUDOERS_FILE"
echo "Sudoers entry created: $SUDOERS_FILE"

# 3. Install cron job (every 5 minutes)
CRON_CMD="*/5 * * * * WIFI_IFACE=${IFACE} $SCRIPT_DST"
CURRENT_CRON=$(crontab -l 2>/dev/null | grep -v "wifi_watchdog" || true)
echo "${CURRENT_CRON}"$'\n'"${CRON_CMD}" | crontab -
echo "Cron job installed (every 5 minutes)"

# 4. Create log file with correct permissions
sudo touch /var/log/wifi_watchdog.log
sudo chown "${USER}:${USER}" /var/log/wifi_watchdog.log
echo "Log file: /var/log/wifi_watchdog.log"

echo ""
echo "=== Done ==="
echo "The watchdog will restart $IFACE if offline for more than 20 minutes."
echo "To monitor: tail -f /var/log/wifi_watchdog.log"
echo "To remove:  crontab -e  (delete the wifi_watchdog line)"
echo "            sudo rm $SUDOERS_FILE $SCRIPT_DST"
