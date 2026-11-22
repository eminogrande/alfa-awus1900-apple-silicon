#!/usr/bin/env bash
# One-click setup: Alfa AWUS1900 (RTL8814AU) on Apple Silicon macOS.
# Installs QEMU, downloads Ubuntu 24.04 minimal arm64, boots headless VM with
# USB 3.0 passthrough, builds & tunes rtl8814au DKMS driver, installs `alfa` TUI.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

[ "$(uname -s)" = Darwin ] || { echo "macOS only"; exit 1; }
[ "$(uname -m)" = arm64 ] || echo "note: tuned for Apple Silicon (arm64)"

command -v brew >/dev/null || { echo "install Homebrew first: https://brew.sh"; exit 1; }
if ! command -v qemu-system-aarch64 >/dev/null; then
  echo "installing qemu (brew)"
  brew install qemu
fi

chmod +x alfa.sh alfa-autoswitch.sh alfa-tui.py
BIN_DIR="$(brew --prefix)/bin"
ln -sf "$DIR/alfa-tui.py" "$BIN_DIR/alfa"
echo "installed global CLI/TUI: $BIN_DIR/alfa"

./alfa.sh image
./alfa.sh up
echo
echo "== building the wifi driver inside the VM (few minutes, needs internet) =="
./alfa.sh driver
echo
if ioreg -p IOUSB -w0 2>/dev/null | grep -q '802\.11ac NIC'; then
  ./alfa.sh usb-on
  ./alfa.sh verify || true
else
  echo "plug the Alfa dongle in now, then run: alfa usb-on && alfa verify"
fi

cat <<EOF

Done. Run the interactive TUI from any terminal:
  alfa

Or use direct CLI commands:
  alfa start                  boot VM + attach USB + join saved Wi-Fi + proxy on
  alfa wifi                   scan networks (sorted by dBm)
  alfa wifi "SSID" "PASS"     join Wi-Fi (prefers 5 GHz, saves to wifi.env)
  alfa proxy on | off         route Mac browsers/apps via Alfa (or back to MacBook)
  alfa bench                  benchmark MacBook Wi-Fi vs Alfa
  alfa stop                   shut down VM & reset Mac proxy

Optional auto-switch LaunchAgent (auto-starts on USB plug-in, falls back on unplug):
  sed "s|__DIR__|$DIR|g" com.alfa.autoswitch.plist.template > ~/Library/LaunchAgents/com.alfa.autoswitch.plist
  launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.alfa.autoswitch.plist
EOF
