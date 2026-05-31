#!/bin/bash
# Configure scheduled display sleep/wake for the Formula Helper kiosk.
# Uses cron + xset DPMS to turn the screen off and on at set times.
#
# Usage:
#   bash setup_display_sleep.sh                  # defaults: sleep 11pm, wake 7am
#   bash setup_display_sleep.sh --sleep 23:00 --wake 07:00

set -e

SLEEP_TIME="23:00"
WAKE_TIME="07:00"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --sleep) SLEEP_TIME="$2"; shift 2 ;;
    --wake)  WAKE_TIME="$2";  shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Parse HH:MM into cron fields
SLEEP_H=$(echo "$SLEEP_TIME" | cut -d: -f1 | sed 's/^0//')
SLEEP_M=$(echo "$SLEEP_TIME" | cut -d: -f2 | sed 's/^0//')
WAKE_H=$(echo "$WAKE_TIME"  | cut -d: -f1 | sed 's/^0//')
WAKE_M=$(echo "$WAKE_TIME"  | cut -d: -f2 | sed 's/^0//')

# Default to 0 if empty (e.g. "00" → stripped to "" by sed)
SLEEP_H=${SLEEP_H:-0}
SLEEP_M=${SLEEP_M:-0}
WAKE_H=${WAKE_H:-0}
WAKE_M=${WAKE_M:-0}

XENV="DISPLAY=:0 XAUTHORITY=/home/${USER}/.Xauthority"
SLEEP_CMD="${XENV} xset dpms force off"
WAKE_CMD="${XENV} xset s reset && ${XENV} xset dpms force on"

echo "=== Formula Helper Display Sleep Setup ==="
echo "  Sleep: $SLEEP_TIME  (cron: $SLEEP_M $SLEEP_H * * *)"
echo "  Wake:  $WAKE_TIME   (cron: $WAKE_M $WAKE_H * * *)"
echo ""

# Remove any existing formula-sleep cron entries
CURRENT_CRON=$(crontab -l 2>/dev/null | grep -v "formula-sleep" || true)

# Add new entries
NEW_CRON=$(cat <<CRON
${CURRENT_CRON}
${SLEEP_M} ${SLEEP_H} * * * ${SLEEP_CMD}  # formula-sleep
${WAKE_M}  ${WAKE_H}  * * * ${WAKE_CMD}   # formula-sleep
CRON
)

echo "$NEW_CRON" | crontab -
echo "Cron jobs installed:"
crontab -l | grep "formula-sleep"
echo ""

# Also disable DPMS auto-blanking in the LXDE autostart so the
# screen doesn't randomly sleep outside of the scheduled window.
AUTOSTART="/etc/xdg/lxsession/LXDE-pi/autostart"
if [ -f "$AUTOSTART" ]; then
  # Remove old xset lines, add ones that disable auto-blanking
  sudo sed -i '/xset/d' "$AUTOSTART"
  echo "@xset s off"        | sudo tee -a "$AUTOSTART" > /dev/null
  echo "@xset -dpms"        | sudo tee -a "$AUTOSTART" > /dev/null
  echo "@xset s noblank"    | sudo tee -a "$AUTOSTART" > /dev/null
  echo "Screen auto-blanking disabled in $AUTOSTART"
fi

echo ""
echo "=== Done ==="
echo "Display will sleep at $SLEEP_TIME and wake at $WAKE_TIME every day."
echo "To change the schedule, re-run this script with --sleep and --wake flags."
echo "To remove the schedule: crontab -e and delete the formula-sleep lines."
