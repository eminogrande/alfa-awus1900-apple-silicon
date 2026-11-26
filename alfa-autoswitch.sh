#!/usr/bin/env bash
# alfa-autoswitch.sh — keeps Alfa ON and default whenever plugged in & enabled.
# Never turns Alfa off for ping spikes or load; yields macOS SOCKS5 cleanly while Open Speedify is bonding,
# and restores Alfa as default immediately when Open Speedify stops.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
cd "$(dirname "$0")" || exit 1

STATE=/tmp/alfa-autoswitch.state
MODE=/tmp/alfa-mode
LOCK=/tmp/alfa-op.pid
LASTATT=0
LASTJOIN=0
JOINFAILS=0
DETACHED=0

has_dongle() { ioreg -p IOUSB -w0 2>/dev/null | grep -q '802\.11ac NIC'; }
speedbond_active() { nc -z 127.0.0.1 19454 2>/dev/null; }
sys_proxy_on() {
  scutil --proxy 2>/dev/null | grep -q 'SOCKSEnable : 1' && return 0
  networksetup -getsocksfirewallproxy Wi-Fi 2>/dev/null | grep -q '^Enabled: Yes'
}
vm_running() {
  [ -f qemu.pid ] || return 1
  local p; p=$(cat qemu.pid 2>/dev/null || true)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && ps -p "$p" -o comm= 2>/dev/null | grep -q qemu
}
op_busy() {
  [ -f "$LOCK" ] || return 1
  local p; p=$(cat "$LOCK" 2>/dev/null || true)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
fallback_mac() {
  local reason=$1
  if sys_proxy_on || [ "$(cat "$STATE" 2>/dev/null)" != "off" ]; then
    ./alfa.sh proxy off >/dev/null 2>&1 || true
    echo off > "$STATE"
    echo "$(date '+%H:%M:%S') macbook direct ($reason)"
  fi
}

while true; do
  if op_busy; then
    sleep 2
    continue
  fi

  mode=$(cat "$MODE" 2>/dev/null || echo on)
  if [ "$mode" = "off" ]; then
    fallback_mac "alfa off"
    sleep 4
    continue
  fi

  if has_dongle; then
    DETACHED=0
    if ! vm_running; then
      echo "$(date '+%H:%M:%S') booting Alfa VM..."
      ./alfa.sh up >/dev/null 2>&1 || { fallback_mac "vm boot failed"; sleep 5; continue; }
    fi

    now=$(date +%s)
    IF=$(./alfa.sh ssh 'iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"' 2>/dev/null || true)
    if [ -z "$IF" ] && [ $((now - LASTATT)) -gt 15 ]; then
      echo "$(date '+%H:%M:%S') attaching USB dongle..."
      ./alfa.sh usb-on >/dev/null 2>&1 || true
      LASTATT=$now
      IF=$(./alfa.sh ssh 'iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"' 2>/dev/null || true)
    fi

    conn=0
    ip4=""
    if [ -n "$IF" ]; then
      conn=$(./alfa.sh ssh "iw dev '$IF' link 2>/dev/null | grep -c 'Connected to'" 2>/dev/null || echo 0)
      ip4=$(./alfa.sh ssh "ip -4 -br a show '$IF' 2>/dev/null | awk '{print \$3}'" 2>/dev/null || true)
      if { [ "$conn" != "1" ] || [ -z "$ip4" ]; } && [ -f wifi.env ] && [ $((now - LASTJOIN)) -gt 20 ]; then
        # shellcheck disable=SC1091
        . ./wifi.env
        if [ -n "${SSID:-}" ]; then
          LASTJOIN=$now
          echo "$(date '+%H:%M:%S') reconnecting $SSID..."
          if ./alfa.sh wifi "$SSID" "${PASS:-}" >/dev/null 2>&1; then
            JOINFAILS=0
          else
            JOINFAILS=$((JOINFAILS + 1))
            echo "$(date '+%H:%M:%S') join $SSID failed (#$JOINFAILS)"
            if [ "$JOINFAILS" -ge 2 ]; then
              echo "$(date '+%H:%M:%S') resetting USB dongle after failed joins..."
              ./alfa.sh usb-on >/dev/null 2>&1 || true
              JOINFAILS=0
            fi
          fi
          IF=$(./alfa.sh ssh 'iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"' 2>/dev/null || true)
          if [ -n "$IF" ]; then
            conn=$(./alfa.sh ssh "iw dev '$IF' link 2>/dev/null | grep -c 'Connected to'" 2>/dev/null || echo 0)
            ip4=$(./alfa.sh ssh "ip -4 -br a show '$IF' 2>/dev/null | awk '{print \$3}'" 2>/dev/null || true)
          fi
        fi
      fi
    fi

    if [ "$conn" = "1" ] && [ -n "$ip4" ]; then
      if speedbond_active; then
        # Yield macOS SOCKS5 while Open Speedify bonds Alfa + all other links; keep VM & Wi-Fi healthy
        if sys_proxy_on || [ "$(cat "$STATE" 2>/dev/null)" != "bonded" ]; then
          ./alfa.sh proxy off >/dev/null 2>&1 || true
          echo bonded > "$STATE"
          echo "$(date '+%H:%M:%S') alfa feeding Open Speedify ($ip4)"
        fi
      else
        prev=$(cat "$STATE" 2>/dev/null || echo off)
        if ! nc -z 127.0.0.1 1080 2>/dev/null || ! sys_proxy_on; then
          ./alfa.sh proxy on >/dev/null 2>&1 || true
        fi
        if [ "$prev" != "on" ]; then
          echo on > "$STATE"
          echo "$(date '+%H:%M:%S') alfa default ON ($ip4)"
        fi
      fi
    else
      # Temporarily clear system SOCKS5 only while Wi-Fi has no IP so Mac stays online
      if ! speedbond_active; then
        fallback_mac "waiting for Wi-Fi"
      fi
    fi
  else
    if vm_running && [ "$DETACHED" = "0" ]; then
      ./alfa.sh usb-off >/dev/null 2>&1 || true
      DETACHED=1
    fi
    fallback_mac "dongle unplugged"
  fi
  sleep 4
done
