#!/usr/bin/env bash
# One-click setup: Alfa AWUS1900 (RTL8814AU) on Apple Silicon macOS.
# Installs QEMU, downloads a small Ubuntu arm64 cloud image, boots a headless VM
# with USB passthrough, builds the rtl8814au DKMS driver. ~1 GB RAM, no GUI.
set -euo pipefail
cd "$(dirname "$0")"

[ "$(uname -s)" = Darwin ] || { echo "macOS only"; exit 1; }
[ "$(uname -m)" = arm64 ] || echo "note: this is tuned for Apple Silicon (arm64)"

command -v brew >/dev/null || { echo "install Homebrew first: https://brew.sh"; exit 1; }
if ! command -v qemu-system-aarch64 >/dev/null; then
  echo "installing qemu (brew)"
  brew install qemu
fi

chmod +x alfa.sh
./alfa.sh image
./alfa.sh up
echo
echo "== building the wifi driver inside the VM (few minutes, needs internet) =="
./alfa.sh driver
echo
if system_profiler SPUSBHostDataType 2>/dev/null | grep -qi "8813"; then
  ./alfa.sh usb-on
  ./alfa.sh verify || true
else
  echo "plug the Alfa dongle in now, then run: ./alfa.sh usb-on && ./alfa.sh verify"
fi

cat <<'EOF'

Done.
  ./alfa.sh ssh          shell in the VM
  ./alfa.sh wifi         list networks   (join: ./alfa.sh wifi "SSID" "PASSWORD")
  ./alfa.sh monitor      put the antenna in monitor mode
  ./alfa.sh managed      back to normal mode
  ./alfa.sh stop         shut the VM down
EOF
