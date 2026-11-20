# Alfa AWUS1900 (RTL8814AU) on Apple Silicon macOS

Realtek never shipped an arm64 macOS driver for the RTL8814AU (Alfa AWUS1900 / AWUS036ACH
family, `0bda:8813`). macOS sees the dongle on USB but creates no network interface.

This runs the dongle inside a **tiny headless Linux VM** (QEMU + Apple `hvf` accel + USB
passthrough) and gives you a one-line CLI. No GUI, no UTM, no desktop, ~1 GB RAM, boots in
~15 s.

## Quick start

```bash
git clone https://github.com/eminogrande/alfa-awus1900-apple-silicon.git
cd alfa-awus1900-apple-silicon
./install.sh
```

Then:

```bash
./alfa.sh ssh                 # shell in the VM
./alfa.sh wifi                # list visible networks (uses the antenna)
./alfa.sh wifi "SSID" "PASS"  # join a network
./alfa.sh monitor             # monitor mode
./alfa.sh managed             # back to normal
./alfa.sh stop                # shut down
```

## Commands

| command | what it does |
|---|---|
| `./install.sh` | install deps, download image, boot VM, build driver |
| `./alfa.sh up` / `stop` | boot / power off the VM (ssh on `127.0.0.1:2222`) |
| `./alfa.sh ssh` | shell into the VM as `alfa` (passwordless sudo) |
| `./alfa.sh driver` | (re)build the `rtl8814au` DKMS module |
| `./alfa.sh usb-on` / `usb-off` | hot-plug the dongle into the running VM |
| `./alfa.sh verify` | load module, show interface, count APs |
| `./alfa.sh wifi [SSID PASS]` | scan, or join a network with wpa_supplicant |
| `./alfa.sh monitor` / `managed` | switch the interface type |
| `./alfa.sh reset` | hard reset the VM |

## How it works

- `qemu-system-aarch64 -machine virt,accel=hvf` — native-speed virtualization, no emulation.
- Ubuntu 24.04 **minimal** arm64 cloud image (215 MB) — cloud-init gets your SSH key, so no
  interactive installer.
- `-device qemu-xhci -device usb-host,vendorid=0x0bda,productid=0x8813` — passthrough of the
  dongle (needs QEMU built with libusb; Homebrew's is).
- `morrownr/8814au` built with DKMS. Ubuntu's 6.8 kernel backports the 3-arg
  `cfg80211_ops.set_monitor_channel`, so the driver's kernel guard is patched to `6.8.0`
  before building (the `driver` command does this automatically).

## Using the antenna instead of the MacBook's Wi-Fi

There is no supported way to hand a USB Wi-Fi adapter from a guest VM to macOS as the host's
uplink: macOS has no `tun/tap`/`vmnet` device a plain QEMU VM can bridge to without a signed
helper (that is what UTM/Parallels ship). Practical options:

1. **Do the Wi-Fi work inside the VM** (recommended). The antenna is a real interface there:
   `./alfa.sh wifi "SSID" "PASS"`, browse from the VM, or point tools at it. To force the
   guest's own internet over the antenna instead of QEMU's NAT:

   ```bash
   ./alfa.sh ssh 'IF=$(iw dev | awk "/Interface/{print \$2;exit}"); GW=$(ip route | awk "/default/{print \$3;exit}"); sudo ip route replace default via $GW dev $IF metric 50'
   ```

2. **Put the dongle on the Raspberry Pi and route through it.** Pi joins Wi-Fi with the
   antenna, `systemd-networkd`/`dnsmasq` NATs its Ethernet, Mac plugs into the Pi's Ethernet
   (or USB-C Ethernet) and sets the Pi as gateway. This is the only way to make the *Mac's*
   traffic use the antenna.

3. Wi-Fi *scanning / monitor mode / injection* — fully supported here, that is what this repo
   is for.

## Troubleshooting

| symptom | fix |
|---|---|
| `dongle not visible to macOS` | `system_profiler SPUSBHostDataType \| grep -i 802.11` — if empty, cable/hub/port; use a data cable and a powered hub |
| macOS *Accessories* prompt | System Settings → Privacy & Security → Allow accessories to connect |
| no interface in VM | `./alfa.sh usb-on && ./alfa.sh verify` |
| `dkms build error ... incompatible-pointer-types` | rerun `./alfa.sh driver` (applies the 6.8 patch) |
| guest wedged after mode switch | `./alfa.sh reset`, then switch mode in a single step (`monitor`/`managed`) |
| `Too many authentication failures` | keys only: the script already sets `IdentitiesOnly=yes` |
| boot hangs | `tail console.log` |

## Files

`alfa.sh` (CLI), `install.sh`, `image.qcow2` (base), `disk.qcow2` (VM), `seed.iso` (cloud-init),
`vars.fd` (UEFI vars), `console.log`, `id_ed25519*`. All generated files are gitignored.

## Notes / limits

- One dongle per VM; the device is claimed by QEMU while attached.
- Guest kernel is Ubuntu 24.04's 6.8 — if you upgrade it, rerun `./alfa.sh driver`.
- Monitor mode is a *mode switch* on the single interface (`iw dev <if> set type monitor`);
  creating an extra `mon0` while the managed interface is up wedges this driver.
- Tested on macOS 27.2.1 (arm64), QEMU 10.x, Alfa AWUS1900, incl. through a USB-C hub.

MIT licensed.
