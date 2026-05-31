#!/bin/bash
# Setup Chromium kiosk mode on Raspberry Pi
# Run as: bash setup_kiosk.sh
#
# This replaces the pygame app with a full-screen Chromium browser
# pointing to the Formula Helper web app.

set -e

PI_KEY="XC3DYLpw4SE0VUb4zvfyLypu3b9eQhnntqkGG_amsAw"
APP_URL="https://d20oyc88hlibbe.cloudfront.net/?pikey=${PI_KEY}"

echo "=== Formula Helper Kiosk Setup ==="
echo ""

# 1. Install Chromium if not present
if ! command -v chromium-browser &> /dev/null && ! command -v chromium &> /dev/null; then
    echo "Installing Chromium..."
    sudo apt-get update && sudo apt-get install -y chromium-browser
fi

CHROMIUM=$(command -v chromium-browser || command -v chromium)
echo "Chromium: $CHROMIUM"

# 2. Install unclutter to hide mouse cursor
if ! command -v unclutter &> /dev/null; then
    echo "Installing unclutter..."
    sudo apt-get install -y unclutter
fi

# 3. Create autostart directory
mkdir -p ~/.config/autostart

# 4. Create kiosk autostart entry
cat > ~/.config/autostart/formula-kiosk.desktop << EOF
[Desktop Entry]
Type=Application
Name=Formula Helper Kiosk
Exec=bash -c 'sleep 5 && unclutter -idle 1 & $CHROMIUM --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --disable-translate --no-first-run --start-fullscreen --autoplay-policy=no-user-gesture-required "$APP_URL"'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

echo "Autostart entry created at ~/.config/autostart/formula-kiosk.desktop"

# 5. Disable screen blanking / power management
if [ -f /etc/xdg/lxsession/LXDE-pi/autostart ]; then
    # Remove existing screen blanking settings
    sudo sed -i '/xset/d' /etc/xdg/lxsession/LXDE-pi/autostart
    # The web app handles its own screensaver
fi

# 6. Stop the old pygame app if running
pkill -f "formula_app.py" 2>/dev/null || true
# Remove old screen session autostart if exists
rm -f ~/.config/autostart/formula-pygame.desktop 2>/dev/null || true

echo ""
echo "=== Setup Complete ==="
echo "URL: $APP_URL"
echo ""
echo "To start now:  $CHROMIUM --kiosk '$APP_URL' &"
echo "To reboot:     sudo reboot"
echo ""
echo "The kiosk will auto-start on next boot."
