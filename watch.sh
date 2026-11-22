#!/usr/bin/env bash
# alfa watch — auto-switch: Alfa when available, MacBook Wi-Fi as fallback.
# Uses hysteresis so transient Wi-Fi bufferbloat during downloads never drops active connections.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
cd "$(dirname "$0")" || exit 1

STATE=/tmp/alfa-watch.state
MODE=/tmp/alfa-mode
LOCK=/tmp/alfa-op.pid
LASTATT=0
LASTJOIN=0
DETACHED=0
FAILS=0

has_dongle() { ioreg -p IOUSB -w0 2>/dev/null | grep -q '802\.11ac NIC'; }
sys_proxy_on() { networksetup -getsocksfirewallproxy Wi-Fi 2>/dev/null | grep -q '^Enabled: Yes'; }
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
    echo "$(date '+%H:%M:%S') fallback: macbook wifi ($reason)"
  fi
}

while true; do
  if op_busy; then
    sleep 2
    continue
  fi

  mode=$(cat "$MODE" 2>/dev/null || echo auto)
  if [ "$mode" = "off" ]; then
    FAILS=0
    fallback_mac "manual off"
    sleep 4
    continue
  fi

  if has_dongle; then
    DETACHED=0
    if ! vm_running; then
      echo "$(date '+%H:%M:%S') starting VM..."
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
    if [ -n "$IF" ]; then
      conn=$(./alfa.sh ssh "iw dev '$IF' link 2>/dev/null | grep -c 'Connected to'" 2>/dev/null || echo 0)
      if [ "$conn" != "1" ] && [ -f wifi.env ] && [ $((now - LASTJOIN)) -gt 30 ]; then
        # shellcheck disable=SC1091
        . ./wifi.env
        if [ -n "${SSID:-}" ]; then
          LASTJOIN=$now
          if ./alfa.sh scan 2>/dev/null | cut -f1 | grep -Fxq "$SSID"; then
            echo "$(date '+%H:%M:%S') joining $SSID..."
            ./alfa.sh wifi "$SSID" "${PASS:-}" >/dev/null 2>&1 || true
            conn=$(./alfa.sh ssh "iw dev '$IF' link 2>/dev/null | grep -c 'Connected to'" 2>/dev/null || echo 0)
          else
            echo "$(date '+%H:%M:%S') saved SSID '$SSID' not in range"
          fi
        fi
      fi
    fi

    if [ "$conn" = "1" ] && [ -n "$IF" ]; then
      # Check reachability; any reply (<100% loss) keeps active sessions alive (ignores bufferbloat under load)
      ql=$(./alfa.sh ssh "ping -I '$IF' -c 3 -W 3 -q 1.1.1.1 2>/dev/null | awk -F'/' '/rtt|packets/{print}'" 2>/dev/null | tr '\n' ' ')
      loss=$(echo "$ql" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+' || echo 100)
      rtt=$(echo "$ql" | awk -F'= ' '/rtt/{print int($2)}')
      if [ "${loss:-100}" -lt 100 ]; then
        FAILS=0
        prev=$(cat "$STATE" 2>/dev/null || echo off)
        if ! nc -z 127.0.0.1 1080 2>/dev/null || ! sys_proxy_on; then
          ./alfa.sh proxy on >/dev/null 2>&1 || true
        fi
        if [ "$prev" != "on" ]; then
          echo on > "$STATE"
          echo "$(date '+%H:%M:%S') alfa on (rtt ${rtt:-?}ms, loss ${loss}%)"
        fi
      else
        FAILS=$((FAILS + 1))
        if [ "$FAILS" -ge 3 ]; then
          fallback_mac "100% packet loss x3"
        fi
      fi
    else
      FAILS=$((FAILS + 1))
      if [ "$FAILS" -ge 2 ]; then
        fallback_mac "wifi disconnected"
      fi
    fi
  else
    FAILS=0
    if vm_running && [ "$DETACHED" = "0" ]; then
      ./alfa.sh usb-off >/dev/null 2>&1 || true
      DETACHED=1
    fi
    fallback_mac "dongle unplugged"
  fi
  sleep 5
done
