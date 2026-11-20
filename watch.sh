#!/usr/bin/env bash
# alfa watch — auto-switch: Alfa when available, MacBook Wi-Fi as fallback.
# Needs wifi.env (SSID="..."; PASS="...") next to alfa.sh for auto-rejoin.
# Run manually or via com.alfa.watch.plist LaunchAgent.
cd "$(dirname "$0")" || exit 1
STATE=/tmp/alfa-watch.state
LASTATT=0
LASTJOIN=0

has_dongle() { ioreg -p IOUSB -w0 | grep -q "802.11ac NIC"; }

while true; do
  if has_dongle; then
    # keep VM up
    if ! [ -f qemu.pid ] || ! kill -0 "$(cat qemu.pid 2>/dev/null)" 2>/dev/null; then
      ./alfa.sh up >/dev/null 2>&1
    fi
    IF=$(./alfa.sh ssh 'iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"' 2>/dev/null || true)
    now=$(date +%s)
    if [ -z "$IF" ]; then
      if [ $((now - LASTATT)) -gt 15 ]; then
        ./alfa.sh usb-on >/dev/null 2>&1
        LASTATT=$now
      fi
    fi
    conn=$(./alfa.sh ssh 'IF=$(iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"); iw dev $IF link 2>/dev/null | grep -c "Connected to"' 2>/dev/null || echo 0)
    if [ "$conn" != "1" ] && [ -f wifi.env ] && [ $((now - LASTJOIN)) -gt 20 ]; then
      # shellcheck disable=SC1091
      . ./wifi.env
      [ -n "${SSID:-}" ] && ./alfa.sh wifi "$SSID" "$PASS" >/dev/null 2>&1
      LASTJOIN=$now
      conn=$(./alfa.sh ssh 'IF=$(iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"); iw dev $IF link 2>/dev/null | grep -c "Connected to"' 2>/dev/null || echo 0)
    fi
    ql=""
    [ "$conn" = "1" ] && ql=$(./alfa.sh ssh 'IF=$(iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"); ping -I "$IF" -c 3 -W 2 -q 1.1.1.1 2>/dev/null | awk -F"/" "/rtt|packets/{print}"' 2>/dev/null | tr "\n" " ")
    loss=$(echo "$ql" | grep -oE "[0-9]+% packet loss" | grep -oE "^[0-9]+" || echo 100)
    rtt=$(echo "$ql" | awk -F"= " "/rtt/{print int(\$2)}")
    if [ "$conn" = "1" ] && [ "${loss:-100}" -le 33 ] && [ -n "${rtt:-}" ] && [ "$rtt" -lt 600 ]; then
      nc -z 127.0.0.1 1080 2>/dev/null || ./alfa.sh proxy on >/dev/null 2>&1
      if [ "$(cat $STATE 2>/dev/null)" != "on" ]; then
        echo on > "$STATE" && echo "$(date '+%H:%M:%S') alfa on"
      fi
    else
      if [ "$(cat $STATE 2>/dev/null)" != "off" ]; then
        ./alfa.sh proxy off >/dev/null 2>&1
        echo off > "$STATE" && echo "$(date '+%H:%M:%S') fallback: macbook wifi"
      fi
    fi
  else
    if [ "$(cat $STATE 2>/dev/null)" != "off" ]; then
      ./alfa.sh proxy off >/dev/null 2>&1
      echo off > "$STATE" && echo "$(date '+%H:%M:%S') fallback: macbook wifi"
    fi
  fi
  sleep 3
done
