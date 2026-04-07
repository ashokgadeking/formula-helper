#!/bin/bash
# wifi_watchdog.sh — Restart WiFi if the Pi has been offline for more than 20 minutes.
# Runs every 5 minutes via cron. Install with: bash setup_wifi_watchdog.sh

OFFLINE_FILE="/tmp/wifi_offline_since"
MAX_OFFLINE_SECS=1200   # 20 minutes
PING_HOST="8.8.8.8"
IFACE="${WIFI_IFACE:-wlan0}"
LOG="/var/log/wifi_watchdog.log"
MAX_LOG_LINES=500

# ── Connectivity check ───────────────────────────────────────────────────────
if ping -c 2 -W 5 "$PING_HOST" &>/dev/null; then
  # Online — clear offline marker silently
  rm -f "$OFFLINE_FILE"
  exit 0
fi

# ── Offline ──────────────────────────────────────────────────────────────────
NOW=$(date +%s)

if [ ! -f "$OFFLINE_FILE" ]; then
  echo "$NOW" > "$OFFLINE_FILE"
  echo "$(date '+%F %T'): offline — timer started" >> "$LOG"
  exit 0
fi

OFFLINE_SINCE=$(cat "$OFFLINE_FILE")
DURATION=$((NOW - OFFLINE_SINCE))
DURATION_MIN=$((DURATION / 60))

if [ "$DURATION" -lt "$MAX_OFFLINE_SECS" ]; then
  echo "$(date '+%F %T'): still offline — ${DURATION_MIN}m elapsed, waiting for 20m" >> "$LOG"
  exit 0
fi

# ── 20 minutes exceeded — restart WiFi ───────────────────────────────────────
echo "$(date '+%F %T'): offline for ${DURATION_MIN}m — restarting $IFACE" >> "$LOG"

# Step 1: toggle the interface
sudo ip link set "$IFACE" down
sleep 3
sudo ip link set "$IFACE" up
sleep 15

if ping -c 2 -W 5 "$PING_HOST" &>/dev/null; then
  echo "$(date '+%F %T'): back online after interface toggle" >> "$LOG"
  rm -f "$OFFLINE_FILE"
else
  # Step 2: restart the network service
  echo "$(date '+%F %T'): interface toggle failed — restarting network service" >> "$LOG"
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    sudo systemctl restart NetworkManager
  else
    sudo systemctl restart dhcpcd
  fi
  sleep 20

  if ping -c 2 -W 5 "$PING_HOST" &>/dev/null; then
    echo "$(date '+%F %T'): back online after service restart" >> "$LOG"
  else
    echo "$(date '+%F %T'): still offline after restart — will retry next cycle" >> "$LOG"
  fi
  rm -f "$OFFLINE_FILE"
fi

# ── Trim log to last MAX_LOG_LINES lines ─────────────────────────────────────
if [ -f "$LOG" ]; then
  tail -n "$MAX_LOG_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
