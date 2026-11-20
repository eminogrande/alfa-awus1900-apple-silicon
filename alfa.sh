#!/usr/bin/env bash
# Alfa AWUS1900 (RTL8814AU) on Apple Silicon macOS.
# No macOS/arm64 driver exists -> run the dongle in a small headless Linux VM
# (QEMU + Apple HVF + USB passthrough). No GUI, no UTM, ~1 GB RAM.
#
#   ./install.sh        first time: deps + image + VM + driver
#   ./alfa.sh up        boot VM (ssh on 127.0.0.1:2222)
#   ./alfa.sh ssh       shell into the VM
#   ./alfa.sh wifi      list / join a network (join: ./alfa.sh wifi SSID PASS)
#   ./alfa.sh monitor   add mon0 in monitor mode
#   ./alfa.sh stop
set -euo pipefail
cd "$(dirname "$0")"

IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img"
IMG_URL_ALT="https://ftp.uni-stuttgart.de/ubuntu-cloud-images/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img"
IMG=image.qcow2
DISK=disk.qcow2
SEED=seed.iso
VARS=vars.fd
KEY=id_ed25519
PID=qemu.pid
MON=monitor.sock
FW=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
VID=0x0bda
PID_USB=0x8813
USB="usb-host,vendorid=$VID,productid=$PID_USB,bus=xhci.0"
SSHOPT="-q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -p 2222 -i $KEY alfa@127.0.0.1"

need_qemu() { command -v qemu-system-aarch64 >/dev/null || { echo "qemu missing: brew install qemu"; exit 1; }; }

get_image() {
  need_qemu
  if [ ! -f $IMG ]; then
    echo "downloading Ubuntu 24.04 minimal arm64 cloud image (~215 MB)"
    curl -fL --retry 3 -C - -o $IMG "$IMG_URL" || curl -fL --retry 3 -C - -o $IMG "$IMG_URL_ALT"
  fi
}

seed() {
  [ -f $KEY ] || ssh-keygen -q -t ed25519 -N "" -f $KEY
  [ -f $VARS ] || dd if=/dev/zero of=$VARS bs=1m count=64 2>/dev/null
  [ -f $SEED ] && return
  rm -rf .seed && mkdir .seed
  cat > .seed/user-data <<EOF
#cloud-config
users:
  - name: alfa
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: [$(cat $KEY.pub)]
  - name: root
    ssh_authorized_keys: [$(cat $KEY.pub)]
EOF
  printf 'instance-id: alfa001\nlocal-hostname: alfa\n' > .seed/meta-data
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name CIDATA -o $SEED .seed
  rm -rf .seed
}

disk() {
  if [ ! -f $DISK ]; then
    qemu-img convert -O qcow2 $IMG $DISK
    qemu-img resize $DISK 8G
  fi
}

up() {
  need_qemu; get_image; seed; disk
  if [ -f $PID ] && kill -0 "$(cat $PID)" 2>/dev/null; then echo "already running"; return; fi
  rm -f $MON console.log
  # attach the dongle only when macOS actually sees it
  USBARG=""
  if system_profiler SPUSBHostDataType 2>/dev/null | grep -qi "${PID_USB#0x}"; then
    USBARG="-device qemu-xhci,id=xhci -device $USB,id=alfa"
  fi
  # shellcheck disable=SC2086
  qemu-system-aarch64 -machine virt,accel=hvf -cpu host -smp 4 -m 1024 \
    -drive if=pflash,format=raw,readonly=on,file=$FW \
    -drive if=pflash,format=raw,file=$VARS \
    -drive file=$DISK,if=none,id=hd0,format=qcow2 -device virtio-blk-pci,drive=hd0 \
    -drive file=$SEED,if=none,id=seed,format=raw,readonly=on -device virtio-blk-pci,drive=seed \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
    $USBARG -display none -serial file:console.log -monitor unix:$MON,server,nowait \
    </dev/null >qemu.out 2>&1 &
  echo $! > $PID
  echo -n "booting"
  for _ in $(seq 60); do ssh $SSHOPT true 2>/dev/null && { echo " ok"; return; }; echo -n .; sleep 2; done
  echo " timeout - see console.log"; exit 1
}

driver() {
  ssh $SSHOPT 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential dkms git iw rfkill nano wpasupplicant isc-dhcp-client linux-modules-extra-$(uname -r)'
  if ssh $SSHOPT 'dkms status 2>/dev/null | grep -q "rtl8814au.*installed"'; then
    echo "driver already installed"; ssh $SSHOPT 'sudo modprobe 8814au; iw dev'; return
  fi
  # Ubuntu 6.8 backports the 3-arg cfg80211 set_monitor_channel; upstream guard is 6.12.101
  ssh $SSHOPT 'rm -rf ~/8814au && git clone -q --depth 1 https://github.com/morrownr/8814au.git ~/8814au && cd ~/8814au &&
    sed -i "s/KERNEL_VERSION(6, 12, 101)/KERNEL_VERSION(6, 8, 0)/g" os_dep/linux/ioctl_cfg80211.c &&
    sudo ./remove-driver.sh >/dev/null 2>&1; sudo dkms remove rtl8814au/5.8.5.1 --all >/dev/null 2>&1; sudo rm -rf /usr/src/rtl8814au-5.8.5.1
    sudo ./install-driver.sh NoPrompt >~/drv.log 2>&1; tail -3 ~/drv.log'
  ssh $SSHOPT 'sudo modprobe 8814au; iw dev'
}

iface() { ssh $SSHOPT 'iw dev 2>/dev/null | awk "/Interface/{print \$2; exit}"'; }

mon() { printf '%s\n' "$1" | nc -U $MON 2>/dev/null || true; }

case ${1:-up} in
  up) up ;;
  image) get_image ;;
  stop) if [ -f $PID ]; then kill "$(cat $PID)" 2>/dev/null || true; rm -f $PID; echo stopped; else echo "not running"; fi ;;
  reset) mon system_reset; echo "reset sent" ;;
  ssh) shift; exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -p 2222 -i $KEY alfa@127.0.0.1 "$@" ;;
  driver) driver ;;
  usb-on)
    if system_profiler SPUSBHostDataType 2>/dev/null | grep -qi "${PID_USB#0x}"; then
      mon "device_del alfa"; sleep 1; mon "device_add $USB,id=alfa"; echo "attached"
    else echo "dongle not visible to macOS (cable/hub/port)"; exit 1; fi ;;
  usb-off) mon "device_del alfa"; echo detached ;;
  verify) ssh $SSHOPT 'sudo modprobe 8814au; iw dev | grep -E "Interface|type"; IF=$(iw dev | awk "/Interface/{print \$2; exit}"); sudo ip link set $IF up; echo -n "APs seen: "; timeout 30 sudo iw dev $IF scan 2>/dev/null | grep -c "^BSS"' ;;
  wifi)
    IF=$(iface); [ -n "$IF" ] || { echo "no wifi interface - is the dongle attached? ./alfa.sh usb-on"; exit 1; }
    if [ -z "${2:-}" ]; then
      exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -p 2222 -i $KEY alfa@127.0.0.1 "sudo ip link set $IF up; sudo iw dev $IF scan 2>/dev/null | grep SSID | sort -u | head -40"
    fi
    printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$2" "${3:?usage: alfa.sh wifi SSID PASS}" > .wpa.conf
    ssh $SSHOPT 'sudo mkdir -p /etc/wpa_supplicant; sudo tee /etc/wpa_supplicant/alfa.conf >/dev/null; sudo pkill wpa_supplicant 2>/dev/null; sleep 1; sudo wpa_supplicant -B -i '"$IF"' -c /etc/wpa_supplicant/alfa.conf; sleep 4; sudo dhclient -1 '"$IF"' || true; ip -br a show '"$IF"'; ip route | head -3' < .wpa.conf
    rm -f .wpa.conf
    echo "note: guest internet still prefers the NAT link; to route guest traffic over the antenna:"
    echo "  ./alfa.sh ssh 'GW=\$(ip route | awk \"/default/{print \\\$3; exit}\"); sudo ip route replace default via \$GW dev $IF metric 50'" ;;
  monitor)
    IF=$(iface); ssh $SSHOPT 'sudo ip link set '"$IF"' down; sudo iw dev '"$IF"' set type monitor; sudo ip link set '"$IF"' up; iw dev '"$IF"' info | head -5' ;;
  managed)
    IF=$(iface); ssh $SSHOPT 'sudo ip link set '"$IF"' down; sudo iw dev '"$IF"' set type managed; sudo ip link set '"$IF"' up; iw dev '"$IF"' info | head -5' ;;
  *) echo "usage: $0 up|stop|reset|ssh|driver|usb-on|usb-off|verify|wifi [SSID PASS]|monitor|managed|image" ;;
esac
