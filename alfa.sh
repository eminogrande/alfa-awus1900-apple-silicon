#!/usr/bin/env bash
# Alfa AWUS1900 (RTL8814AU) on Apple Silicon macOS.
# Headless QEMU (Apple HVF) + USB 3.0 passthrough + tuned DKMS driver + SOCKS5 proxy + benchmark.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
cd "$(dirname "$0")"

IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img"
IMG_URL_ALT="https://ftp.uni-stuttgart.de/ubuntu-cloud-images/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img"
IMG=image.qcow2
DISK=disk.qcow2
SEED=seed.iso
VARS=vars.fd
KEY=id_ed25519
PID=qemu.pid
PROXY_PID=proxy.pid
PROXY_PORT=${ALFA_PROXY_PORT:-1080}
MON=monitor.sock
MODE_FILE=/tmp/alfa-mode
STATE_FILE=/tmp/alfa-autoswitch.state
LOCK_FILE=/tmp/alfa-op.pid
FW=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
VID=0x0bda
PID_USB=0x8813
USB="usb-host,vendorid=$VID,productid=$PID_USB,bus=xhci.0"
SSH_ARGS=(-q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=3 -o IdentitiesOnly=yes -o PreferredAuthentications=publickey
  -o PasswordAuthentication=no -c aes128-gcm@openssh.com -p 2222 -i "$KEY")
SSH_TARGET="alfa@127.0.0.1"

ssh_q() { ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "$@"; }
need_qemu() { command -v qemu-system-aarch64 >/dev/null || { echo "qemu missing: brew install qemu"; exit 1; }; }
mon() { [ -S "$MON" ] && printf '%s\n' "$1" | nc -U -w 2 "$MON" >/dev/null 2>&1 || true; }
host_has_dongle() { ioreg -p IOUSB -w0 2>/dev/null | grep -q '802\.11ac NIC'; }
speedbond_active() { nc -z 127.0.0.1 19454 2>/dev/null; }
vm_running() {
  [ -f "$PID" ] || return 1
  local p; p=$(cat "$PID" 2>/dev/null || true)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && ps -p "$p" -o comm= 2>/dev/null | grep -q qemu
}
proxy_running() {
  if [ -f "$PROXY_PID" ]; then
    local p; p=$(cat "$PROXY_PID" 2>/dev/null || true)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null && return 0
  fi
  nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null && pgrep -f "ssh.*127\.0\.0\.1:$PROXY_PORT" >/dev/null 2>&1
}
physical_services() {
  networksetup -listnetworkserviceorder 2>/dev/null | awk '
    /^\([0-9]+\) / { name=$0; sub(/^\([0-9]+\) /, "", name); next }
    /\(Hardware Port:.*Device: en[0-9]+\)/ && name != "" { print name; name="" }
  '
}
sys_proxy_on() {
  scutil --proxy 2>/dev/null | grep -q 'SOCKSEnable : 1' && return 0
  networksetup -getsocksfirewallproxy Wi-Fi 2>/dev/null | grep -q '^Enabled: Yes'
}
iface() { ssh_q 'iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"' 2>/dev/null || true; }

with_lock() {
  echo "$$" > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT
}

get_image() {
  need_qemu
  [ -f "$DISK" ] && return 0
  if [ ! -f "$IMG" ]; then
    echo "downloading Ubuntu 24.04 minimal arm64 cloud image (~215 MB)"
    curl -fL --retry 3 -C - -o "$IMG" "$IMG_URL" || curl -fL --retry 3 -C - -o "$IMG" "$IMG_URL_ALT"
  fi
}

seed() {
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEY"
  [ -f "$VARS" ] || dd if=/dev/zero of="$VARS" bs=1m count=64 2>/dev/null
  [ -f "$SEED" ] && return
  rm -rf .seed && mkdir .seed
  cat > .seed/user-data <<EOF
#cloud-config
users:
  - name: alfa
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: [$(cat "$KEY.pub")]
  - name: root
    ssh_authorized_keys: [$(cat "$KEY.pub")]
EOF
  printf 'instance-id: alfa001\nlocal-hostname: alfa\n' > .seed/meta-data
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name CIDATA -o "$SEED" .seed
  rm -rf .seed
}

disk() {
  if [ ! -f "$DISK" ]; then
    qemu-img convert -O qcow2 "$IMG" "$DISK"
    qemu-img resize "$DISK" 8G
  fi
}

usb_attach() {
  vm_running || { echo "VM not running - run ./alfa.sh up"; exit 1; }
  host_has_dongle || { echo "dongle not visible to macOS (check cable/hub/port)"; exit 1; }
  mon "device_del alfa"; sleep 1
  mon "device_add $USB,id=alfa"; sleep 3
  # rtw_switch_usb_mode=1 resets the dongle from USB 2.0 (480M) to USB 3.0 (5000M); re-attach once if needed
  if ! ssh_q 'lsusb -t 2>/dev/null | grep -q "rtl8814au, 5000M"' 2>/dev/null; then
    if host_has_dongle; then
      mon "device_del alfa"; sleep 1
      mon "device_add $USB,id=alfa"; sleep 3
    fi
  fi
  ssh_q 'sudo modprobe 8814au 2>/dev/null || true' 2>/dev/null || true
  for _ in $(seq 8); do
    [ -n "$(iface)" ] && break
    sleep 1
  done
  ssh_q 'lsusb -t | grep -E "rtl8814au|5000M|480M" | grep -v root_hub || true' 2>/dev/null || true
}

daemonize() {
  local pidfile=$1 log=$2; shift 2
  perl -MPOSIX=setsid -e '
    my ($pf, $lg) = splice(@ARGV, 0, 2);
    my $pid = fork(); die "fork: $!" unless defined $pid;
    if ($pid) { open my $f, ">", $pf or die $!; print $f "$pid\n"; close $f; exit 0; }
    setsid() or die "setsid: $!";
    open STDIN, "<", "/dev/null";
    open STDOUT, ">", $lg;
    open STDERR, ">&STDOUT";
    exec @ARGV or die "exec: $!";
  ' "$pidfile" "$log" "$@"
}

up() {
  need_qemu; get_image; seed; disk
  if vm_running; then echo "already running"; return 0; fi
  rm -f "$MON" "$PID" console.log
  local usb_dev=()
  if host_has_dongle; then usb_dev=(-device "$USB,id=alfa"); fi
  # Fork + setsid before exec so QEMU detaches from caller's process group (survives SIGHUP)
  daemonize "$PID" qemu.out qemu-system-aarch64 -machine virt,accel=hvf -cpu host -smp 2 -m 512 \
    -drive if=pflash,format=raw,readonly=on,file="$FW" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK",if=none,id=hd0,format=qcow2 -device virtio-blk-pci,drive=hd0 \
    -drive file="$SEED",if=none,id=seed,format=raw,readonly=on -device virtio-blk-pci,drive=seed \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
    -device qemu-xhci,id=xhci ${usb_dev[@]+"${usb_dev[@]}"} \
    -display none -serial file:console.log -monitor "unix:$MON,server,nowait"
  echo -n "booting"
  for _ in $(seq 60); do
    vm_running || { echo " crashed - see qemu.out"; rm -f "$PID"; exit 1; }
    ssh_q true 2>/dev/null && { echo " ok"; break; }
    echo -n .; sleep 2
  done
  ssh_q true 2>/dev/null || { echo " timeout - see console.log"; exit 1; }
  if host_has_dongle && ! ssh_q 'lsusb -t 2>/dev/null | grep -q "rtl8814au, 5000M"' 2>/dev/null; then
    usb_attach >/dev/null || true
  fi
}

stop_vm() {
  echo off > "$MODE_FILE" 2>/dev/null || true
  proxy_off >/dev/null 2>&1 || true
  if vm_running; then
    local p; p=$(cat "$PID")
    kill "$p" 2>/dev/null || true
    for _ in $(seq 15); do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$p" 2>/dev/null || true
    rm -f "$PID" "$MON"
    echo "stopped"
  else
    rm -f "$PID" "$MON"
    echo "not running"
  fi
}

tune() {
  ssh_q 'sudo tee /etc/modprobe.d/8814au.conf >/dev/null <<EOF
options 8814au rtw_switch_usb_mode=1 rtw_drv_log_level=0 rtw_led_ctrl=1 rtw_power_mgnt=0 rtw_ips_mode=0 rtw_enusbss=0 rtw_vht_enable=1 rtw_rx_ampdu_amsdu=1
EOF
sudo tee /etc/sysctl.d/99-alfa-net.conf >/dev/null <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF
echo tcp_bbr | sudo tee /etc/modules-load.d/bbr.conf >/dev/null
sudo modprobe tcp_bbr 2>/dev/null || true
sudo sysctl --system >/dev/null 2>&1
sudo modprobe -r 8814au 2>/dev/null || true
sudo modprobe 8814au 2>/dev/null || true'
  if host_has_dongle; then usb_attach; fi
  ssh_q 'IF=$(iw dev | awk "/Interface/{print \$2;exit}"); [ -n "$IF" ] && sudo iw dev "$IF" set power_save off 2>/dev/null || true; sysctl -n net.ipv4.tcp_congestion_control net.core.default_qdisc | tr "\n" " "; echo'
}

driver() {
  ssh_q 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential dkms git iw rfkill nano wpasupplicant isc-dhcp-client iputils-ping linux-headers-generic linux-headers-$(uname -r) linux-modules-extra-$(uname -r)'
  if ssh_q 'dkms status 2>/dev/null | grep -q "rtl8814au.*$(uname -r).*installed"'; then
    echo "driver already installed for $(uname -r)"
  else
    # Try dkms autoinstall first if source is already registered; else fresh clone & build
    ssh_q 'sudo dkms autoinstall -k $(uname -r) 2>/dev/null || true'
    if ! ssh_q 'dkms status 2>/dev/null | grep -q "rtl8814au.*$(uname -r).*installed"'; then
      # Ubuntu 6.8 backports the 3-arg cfg80211 set_monitor_channel; upstream guard is 6.12.101
      ssh_q 'rm -rf ~/8814au && git clone -q --depth 1 https://github.com/morrownr/8814au.git ~/8814au && cd ~/8814au &&
        sed -i "s/KERNEL_VERSION(6, 12, 101)/KERNEL_VERSION(6, 8, 0)/g" os_dep/linux/ioctl_cfg80211.c &&
        sudo ./remove-driver.sh >/dev/null 2>&1; sudo dkms remove rtl8814au/5.8.5.1 --all >/dev/null 2>&1; sudo rm -rf /usr/src/rtl8814au-5.8.5.1
        sudo ./install-driver.sh NoPrompt >~/drv.log 2>&1; tail -3 ~/drv.log'
    fi
  fi
  tune
  ssh_q 'iw dev | grep -E "Interface|type|txpower"'
}

clear_sys_proxy() {
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] && networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
  done < <(physical_services)
}

enable_sys_proxy() {
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 "$PROXY_PORT" 2>/dev/null || true
    networksetup -setsocksfirewallproxystate "$svc" on 2>/dev/null || true
  done < <(physical_services)
}

proxy_off() {
  clear_sys_proxy
  if [ -f "$PROXY_PID" ]; then
    kill "$(cat "$PROXY_PID" 2>/dev/null)" 2>/dev/null || true
    rm -f "$PROXY_PID"
  fi
  pkill -f "ssh.*-D 127\.0\.0\.1:$PROXY_PORT" 2>/dev/null || true
  echo off > "$STATE_FILE" 2>/dev/null || true
  echo "proxy off (macOS Wi-Fi direct)"
}

proxy_on() {
  local set_sys=${1:-1}
  vm_running || { echo "VM not running - run ./alfa.sh up"; exit 1; }
  if proxy_running; then
    echo "socks5 already running on 127.0.0.1:$PROXY_PORT"
  else
    rm -f "$PROXY_PID"
    daemonize "$PROXY_PID" /dev/null ssh "${SSH_ARGS[@]}" -N -D "127.0.0.1:$PROXY_PORT" \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      "$SSH_TARGET"
    local ok=0
    for _ in $(seq 15); do
      nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null && { ok=1; break; }
      kill -0 "$(cat "$PROXY_PID" 2>/dev/null)" 2>/dev/null || break
      sleep 0.2
    done
    if [ "$ok" != 1 ]; then
      rm -f "$PROXY_PID"
      echo "proxy failed to start"
      exit 1
    fi
    echo "socks5 running on 127.0.0.1:$PROXY_PORT (aes128-gcm)"
  fi
  if [ "$set_sys" = 1 ]; then
    if speedbond_active; then
      clear_sys_proxy
      echo bonded > "$STATE_FILE" 2>/dev/null || true
      echo "Open Speedify active — Alfa ready for bonding"
    else
      enable_sys_proxy
      echo on > "$STATE_FILE" 2>/dev/null || true
      echo "macOS system SOCKS proxy -> ON (Alfa is default across all network services)"
    fi
  fi
}

scan_cmd() {
  local ifc raw
  ifc=$(iface)
  [ -n "$ifc" ] || return 0
  # Try fresh scan; fall back to cached scan dump if wpa_supplicant is busy scanning
  raw=$(ssh_q "sudo ip link set '$ifc' up 2>/dev/null; out=\$(sudo iw dev '$ifc' scan 2>/dev/null || true); [ -n \"\$out\" ] && printf '%s\n' \"\$out\" || sudo iw dev '$ifc' scan dump 2>/dev/null || true" 2>/dev/null || true)
  printf '%s\n' "$raw" | awk '
    /^BSS /{if(s!="" && (!(s in best) || sig+0 > best[s]+0)){best[s]=sig; bf[s]=f} s=""; f=""; sig=-100}
    /freq:/{f=$2}
    /signal:/{sig=$2}
    /SSID:/{s=substr($0,index($0,"SSID:")+6); gsub(/\r/,"",s)}
    END{
      if(s!="" && (!(s in best) || sig+0 > best[s]+0)){best[s]=sig; bf[s]=f}
      for(k in best) printf "%s\t%.0f\t%.0f\n", k, best[k], bf[k]
    }' | sort -t $'\t' -k2,2rn
}

wifi_cmd() {
  local ifc
  ifc=$(iface)
  [ -n "$ifc" ] || { echo "no wifi interface - run ./alfa.sh usb-on"; exit 1; }
  if [ "${1:-}" = "off" ]; then
    ssh_q "sudo pkill -x wpa_supplicant 2>/dev/null || true; sudo pkill -x dhclient 2>/dev/null || true; sudo ip addr flush dev $ifc; sudo resolvectl revert $ifc 2>/dev/null || true; echo disconnected"
    return
  fi
  if [ -z "${1:-}" ]; then
    ssh_q "sudo ip link set $ifc up; sudo iw dev $ifc scan 2>/dev/null | awk '/^BSS/{s=\"\";f=\"\"} /freq:/{f=\$2} /signal:/{sig=\$2} /SSID:/{s=substr(\$0,index(\$0,\"SSID:\")+6); if(s!=\"\") printf \"%6.1f dBm  %4.0f MHz  %s\\n\", sig, f, s}' | sort -rn | head -25"
    return
  fi
  local ssid=$1 pass=${2:-}
  local ssid_esc=${ssid//\\/\\\\}; ssid_esc=${ssid_esc//\"/\\\"}
  local auth='key_mgmt=NONE'
  if [ -n "$pass" ]; then
    local pass_esc=${pass//\\/\\\\}; pass_esc=${pass_esc//\"/\\\"}
    auth=$(printf 'psk="%s"' "$pass_esc")
  fi
  local f5="5180 5200 5220 5240 5260 5280 5300 5320 5500 5520 5540 5560 5580 5600 5620 5640 5660 5680 5700 5745 5765 5785 5805 5825"
  # Prefer 5 GHz (802.11ac) via higher priority; fall back to 2.4 GHz if SSID is 2.4-only
  printf 'ctrl_interface=/run/wpa_supplicant\nnetwork={\n\tssid="%s"\n\t%s\n\tfreq_list=%s\n\tpriority=2\n}\nnetwork={\n\tssid="%s"\n\t%s\n\tpriority=1\n}\n' \
    "$ssid_esc" "$auth" "$f5" "$ssid_esc" "$auth" | ssh_q "sudo mkdir -p /etc/wpa_supplicant && sudo install -m 600 /dev/stdin /etc/wpa_supplicant/alfa.conf &&
    sudo pkill -x wpa_supplicant 2>/dev/null || true; sudo pkill -x dhclient 2>/dev/null || true; sudo rm -f /run/wpa_supplicant/$ifc; sleep 1
    sudo ip link set $ifc up && sudo iw dev $ifc set power_save off 2>/dev/null || true
    sudo wpa_supplicant -B -i $ifc -c /etc/wpa_supplicant/alfa.conf >/dev/null
    for _ in \$(seq 20); do iw dev $ifc link | grep -q 'Connected to' && break; sleep 1; done
    iw dev $ifc link | grep -q 'Connected to' || { echo 'failed to associate (check SSID/pass)'; exit 1; }
    sudo dhclient -1 $ifc
    ip -4 -br a show $ifc | grep -q '[0-9]\.' || { echo 'failed to get IPv4 via DHCP'; exit 1; }
    GW=\$(ip route show | awk -v d=$ifc '\$1==\"default\" && \$0 ~ \"dev \"d {print \$3; exit}')
    if [ -n \"\$GW\" ]; then
      sudo ip route del default dev $ifc 2>/dev/null || true
      sudo ip route replace default via \"\$GW\" dev $ifc metric 10
      sudo resolvectl dns $ifc 1.1.1.1 8.8.8.8 2>/dev/null || true
      sudo resolvectl domain $ifc '~.' 2>/dev/null || true
    fi
    iw dev $ifc link | grep -E 'Connected|SSID|freq|signal|tx bitrate|rx bitrate'
    ip -br a show $ifc"
  # Persist last working Wi-Fi credentials for auto-rejoin
  printf 'SSID=%q\nPASS=%q\n' "$ssid" "$pass" > wifi.env
  chmod 600 wifi.env
}

start_all() {
  with_lock
  echo on > "$MODE_FILE"
  up
  if host_has_dongle; then
    [ -n "$(iface)" ] || usb_attach || true
    local ifc; ifc=$(iface)
    if [ -n "$ifc" ]; then
      local conn ip4
      conn=$(ssh_q "iw dev $ifc link 2>/dev/null | grep -c 'Connected to'" 2>/dev/null || echo 0)
      ip4=$(ssh_q "ip -4 -br a show $ifc 2>/dev/null | awk '{print \$3}'" 2>/dev/null || true)
      if { [ "$conn" != "1" ] || [ -z "$ip4" ]; } && [ -f wifi.env ]; then
        # shellcheck disable=SC1091
        . ./wifi.env
        [ -n "${SSID:-}" ] && wifi_cmd "$SSID" "${PASS:-}" || true
      fi
      conn=$(ssh_q "iw dev $ifc link 2>/dev/null | grep -c 'Connected to'" 2>/dev/null || echo 0)
      ip4=$(ssh_q "ip -4 -br a show $ifc 2>/dev/null | awk '{print \$3}'" 2>/dev/null || true)
      if [ "$conn" = "1" ] && [ -n "$ip4" ]; then
        proxy_on 1
      else
        echo "VM up, pick a Wi-Fi network to connect"
      fi
    fi
  else
    echo "VM up (plug in Alfa dongle to connect)"
  fi
}

status_cmd() {
  local dongle=0 vm=0 prx=0 sysp=0 watch=0 bonded=0 mode=on
  local ifc="" ssid="" freq="" sig="" ip4=""
  host_has_dongle && dongle=1
  vm_running && vm=1
  proxy_running && prx=1
  sys_proxy_on && sysp=1
  speedbond_active && bonded=1
  pgrep -f "alfa-autoswitch\.sh" >/dev/null 2>&1 && watch=1
  [ -f "$MODE_FILE" ] && mode=$(cat "$MODE_FILE" 2>/dev/null || echo on)
  if [ "$vm" = 1 ]; then
    local g
    g=$(ssh_q '
      IF=$(iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}")
      printf "iface=%s\n" "$IF"
      if [ -n "$IF" ]; then
        iw dev "$IF" link 2>/dev/null | awk "
          /SSID:/{print \"ssid=\" substr(\$0, index(\$0,\"SSID:\")+6)}
          /freq:/{print \"freq=\" \$2}
          /signal:/{print \"signal=\" \$2}"
        printf "ip=%s\n" "$(ip -4 -br a show "$IF" 2>/dev/null | awk "{print \$3}")"
      fi
    ' 2>/dev/null || true)
    ifc=$(printf '%s\n' "$g" | awk -F= '$1=="iface"{print $2; exit}')
    ssid=$(printf '%s\n' "$g" | awk -F= '$1=="ssid"{sub(/^ssid=/,""); print; exit}')
    freq=$(printf '%s\n' "$g" | awk -F= '$1=="freq"{print $2; exit}')
    sig=$(printf '%s\n' "$g" | awk -F= '$1=="signal"{print $2; exit}')
    ip4=$(printf '%s\n' "$g" | awk -F= '$1=="ip"{print $2; exit}')
  fi
  printf 'dongle=%s\nvm=%s\niface=%s\nssid=%s\nfreq=%s\nsignal=%s\nip=%s\nproxy=%s\nsys_proxy=%s\nwatch=%s\nbonded=%s\nmode=%s\n' \
    "$dongle" "$vm" "$ifc" "$ssid" "$freq" "$sig" "$ip4" "$prx" "$sysp" "$watch" "$bonded" "$mode"
}

bench() {
  local ifc
  ifc=$(iface)
  echo "=== RF & LINK ==="
  printf "MacBook en0: "
  system_profiler SPAirPortDataType 2>/dev/null | awk '
    /Current Network Information:/{incur=1}
    incur && /PHY Mode:/{phy=$3}
    incur && /Channel:/{ch=$2" "$3" "$4}
    incur && /Signal \/ Noise:/{sig=$4" "$5"/"$7" "$8}
    incur && /Transmit Rate:/{tx=$3; incur=0}
    END{printf "PHY=%s ch=%s sig=%s tx=%s Mbps\n", phy, ch, sig, tx}'
  printf "Alfa USB:    "
  system_profiler SPUSBHostDataType 2>/dev/null | awk '/802\.11ac NIC:/{f=1} f && /Link Speed:/{sp=$3" "$4} f && /Power Allocated:/{pw=$3" "$4" "$5" "$6; f=0} END{printf "speed=%s power=%s\n", sp, pw}'
  if [ -n "$ifc" ]; then
    ssh_q "IF=$ifc; echo -n 'Alfa Link:   '; iw dev \$IF link | awk '/Connected/{c=1} /freq:/{f=\$2} /signal:/{s=\$2\" \"\$3} /tx bitrate:/{tx=\$3\" \"\$4} /rx bitrate:/{rx=\$3\" \"\$4} END{if(c) printf \"freq=%sMHz sig=%s tx=%s rx=%s\\n\",f,s,tx,rx; else print \"not associated (run ./alfa.sh wifi SSID PASS)\"}'"
    printf "APs seen:    Mac=%s | Alfa=" "$(($(system_profiler SPAirPortDataType 2>/dev/null | grep -c "PHY Mode:") - 1))"
    ssh_q "sudo ip link set $ifc up; sudo iw dev $ifc scan 2>/dev/null | awk '/^BSS/{b++} /freq: 24/{g2++} /freq: 5/{g5++} END{printf \"%d (2.4G:%d 5G:%d)\\n\", b, g2, g5}'"
  fi

  echo "=== LATENCY (10 pings -> 1.1.1.1) ==="
  printf "MacBook en0: "
  ping -c 10 -i 0.2 -q 1.1.1.1 2>&1 | awk -F'= ' '/round-trip/{print $2}' | tr '\n' ' '; echo
  local alfa_ip=""
  [ -n "$ifc" ] && alfa_ip=$(ssh_q "ip -4 -br a show $ifc | awk '{print \$3}'")
  if [ -n "$alfa_ip" ]; then
    printf "Alfa direct: "
    ssh_q "ping -I $ifc -c 10 -i 0.2 -q 1.1.1.1 2>&1 | awk -F'= ' '/rtt/{print \$2}'"
  else
    echo "Alfa direct: skipped (not connected to Wi-Fi)"
  fi

  echo "=== THROUGHPUT (Cloudflare 25MB down / 5MB up) ==="
  local mac_dn mac_up
  mac_dn=$(curl --noproxy '*' -s -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=25000000' | awk '{printf "%.1f Mbps", $1*8/1e6}')
  mac_up=$(dd if=/dev/zero bs=1m count=5 2>/dev/null | curl --noproxy '*' -s -o /dev/null -w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up' | awk '{printf "%.1f Mbps", $1*8/1e6}')
  printf "MacBook en0:       down=%-11s up=%s\n" "$mac_dn" "$mac_up"

  if [ -n "$alfa_ip" ]; then
    local alfa_dn alfa_up
    alfa_dn=$(ssh_q "curl --interface $ifc -s -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=25000000' | awk '{printf \"%.1f Mbps\", \$1*8/1e6}'")
    alfa_up=$(ssh_q "dd if=/dev/zero bs=1M count=5 2>/dev/null | curl --interface $ifc -s -o /dev/null -w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up' | awk '{printf \"%.1f Mbps\", \$1*8/1e6}'")
    printf "Alfa direct (VM):  down=%-11s up=%s\n" "$alfa_dn" "$alfa_up"
    if proxy_running; then
      local prx_dn prx_up
      prx_dn=$(curl --socks5-hostname "127.0.0.1:$PROXY_PORT" -s -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=25000000' | awk '{printf "%.1f Mbps", $1*8/1e6}')
      prx_up=$(dd if=/dev/zero bs=1m count=5 2>/dev/null | curl --socks5-hostname "127.0.0.1:$PROXY_PORT" -s -o /dev/null -w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up' | awk '{printf "%.1f Mbps", $1*8/1e6}')
      printf "Mac via Alfa:      down=%-11s up=%s\n" "$prx_dn" "$prx_up"
    fi
  else
    echo "Alfa direct (VM):  connect first -> ./alfa.sh wifi \"SSID\" \"PASS\""
  fi
}

case ${1:-up} in
  up) with_lock; up ;;
  start) start_all ;;
  image) get_image ;;
  stop) with_lock; stop_vm ;;
  reset) mon system_reset; echo "reset sent" ;;
  ssh) shift; exec ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -c aes128-gcm@openssh.com -p 2222 -i "$KEY" "$SSH_TARGET" "$@" ;;
  driver) driver ;;
  tune) tune ;;
  usb-on) with_lock; usb_attach ;;
  usb-off) mon "device_del alfa"; echo detached ;;
  verify) ssh_q 'sudo modprobe 8814au; lsusb -t | grep rtl8814au; iw dev | grep -E "Interface|type|txpower"; IF=$(iw dev | awk "/Interface/{print \$2;exit}"); sudo ip link set "$IF" up; echo -n "APs seen: "; timeout 30 sudo iw dev "$IF" scan 2>/dev/null | grep -c "^BSS"' ;;
  scan) scan_cmd ;;
  wifi) shift; with_lock; wifi_cmd "$@" ;;
  status) status_cmd ;;
  proxy)
    case ${2:-on} in
      on) with_lock; proxy_on 1 ;;
      cli) with_lock; proxy_on 0 ;;
      off) with_lock; proxy_off ;;
      status)
        proxy_running && echo "socks5: up (127.0.0.1:$PROXY_PORT)" || echo "socks5: down"
        networksetup -getsocksfirewallproxy Wi-Fi 2>/dev/null | head -3 ;;
      *) echo "usage: $0 proxy on|cli|off|status" ;;
    esac ;;
  bench) bench ;;
  monitor)
    IF=$(iface); ssh_q "sudo ip link set $IF down; sudo iw dev $IF set type monitor; sudo ip link set $IF up; iw dev $IF info | head -5" ;;
  managed)
    IF=$(iface); ssh_q "sudo ip link set $IF down; sudo iw dev $IF set type managed; sudo ip link set $IF up; iw dev $IF info | head -5" ;;
  *) echo "usage: $0 start|up|stop|status|reset|ssh|driver|tune|usb-on|usb-off|verify|scan|wifi [SSID PASS|off]|proxy [on|cli|off|status]|bench|monitor|managed|image" ;;
esac
