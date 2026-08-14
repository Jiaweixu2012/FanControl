#!/bin/bash
# FanControlHelper installer — run with admin rights.
# Usage: install.sh <AppBundlePath>   (e.g. /Applications/FanControl.app)
set -e

HELPER_NAME="FanControlHelper"
INSTALL_DIR="/Library/PrivilegedHelperTools"
PLIST_PATH="/Library/LaunchDaemons/com.fancontrol.helper.plist"
APP_BUNDLE="${1:?usage: install.sh <AppBundlePath>}"

mkdir -p "$INSTALL_DIR"
cp "$APP_BUNDLE/Contents/Resources/$HELPER_NAME" "$INSTALL_DIR/$HELPER_NAME"
chown root:wheel "$INSTALL_DIR/$HELPER_NAME"
chmod 755 "$INSTALL_DIR/$HELPER_NAME"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.fancontrol.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/$HELPER_NAME</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/fancontrol-helper.log</string>
    <key>StandardErrorPath</key><string>/var/log/fancontrol-helper.log</string>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

launchctl bootstrap system "$PLIST_PATH" 2>/dev/null || \
    launchctl load "$PLIST_PATH" 2>/dev/null || true

sleep 1
echo "FanControlHelper installed."
