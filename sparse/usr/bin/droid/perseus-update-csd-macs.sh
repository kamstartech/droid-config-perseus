#!/bin/sh
# Capture live WiFi and Bluetooth MAC addresses and seed them into the
# CSD hardware-settings file so the MAC-address auto-test passes.
# Runs as a oneshot service after wlan0 / hci0 are available.

CFG=/usr/share/csd/settings.d/99-perseus-hw-settings.ini
WIFI_MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null)
BT_MAC=$(cat /sys/class/bluetooth/hci0/address 2>/dev/null)

[ -f "$CFG" ] || exit 0
[ -n "$WIFI_MAC" ] || [ -n "$BT_MAC" ] || exit 0

# Ensure a [mac] section exists.
if ! grep -q '^\[mac\]' "$CFG" 2>/dev/null; then
    printf '\n[mac]\n' >> "$CFG"
fi

if [ -n "$WIFI_MAC" ] && ! grep -q '^wireless=' "$CFG"; then
    echo "wireless=$WIFI_MAC" >> "$CFG"
fi

if [ -n "$BT_MAC" ] && ! grep -q '^bluetooth=' "$CFG"; then
    echo "bluetooth=$BT_MAC" >> "$CFG"
fi
