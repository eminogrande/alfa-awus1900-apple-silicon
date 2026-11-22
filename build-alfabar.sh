#!/bin/bash
# Build AlfaBar.app (menu bar controller for the Alfa antenna). Needs Xcode CLT (swiftc).
set -euo pipefail
cd "$(dirname "$0")/AlfaBar"
pkill -x AlfaBar 2>/dev/null || true
swiftc -O -o AlfaBar main.swift
APP=AlfaBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AlfaBar</string>
  <key>CFBundleIdentifier</key><string>com.alfa.bar</string>
  <key>CFBundleExecutable</key><string>AlfaBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
mv AlfaBar "$APP/Contents/MacOS/AlfaBar"
echo "built $PWD/$APP"

PLIST="$HOME/Library/LaunchAgents/com.alfabar.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.alfabar</string>
  <key>ProgramArguments</key><array><string>open</string><string>-g</string><string>$PWD/$APP</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict></plist>
EOF
UID_NUM=$(id -u)
launchctl bootout "gui/$UID_NUM/com.alfabar" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
open -g "$PWD/$APP"
echo "AlfaBar launched + LaunchAgent installed"
