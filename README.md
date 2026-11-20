# Alfa AWUS1900 (RTL8814AU) on Apple Silicon macOS

Realtek never shipped an arm64 macOS driver for the RTL8814AU (Alfa AWUS1900 / AWUS036ACH
family, `0bda:8813`). macOS sees the dongle on USB but creates no network interface.

This runs the dongle inside a **tiny headless Linux VM** (QEMU + Apple `hvf` + USB 3.0
SuperSpeed passthrough + tuned DKMS driver + `aes128-gcm` SOCKS5 proxy) with a one-line CLI.
No GUI, no UTM, no desktop, ~1 GB RAM, boots in ~15 s.

## Quick start

```bash
git clone https://github.com/eminogrande/alfa-awus1900-apple-silicon.git
cd alfa-awus1900-apple-silicon
./install.sh
```

Then:

```bash
./alfa.sh wifi                 # scan networks sorted by signal (dBm)
./alfa.sh wifi "SSID" "PASS"   # join Wi-Fi & route VM traffic over the antenna
./alfa.sh proxy on             # route Mac browsers/apps over the Alfa (SOCKS5 127.0.0.1:1080)
./alfa.sh watch (LaunchAgent)   # AUTO: Alfa when available, MacBook Wi-Fi fallback
./alfa.sh bench                # benchmark MacBook Wi-Fi vs Alfa head-to-head
./alfa.sh proxy off            # restore direct MacBook Wi-Fi
./alfa.sh monitor              # switch antenna to monitor mode
./alfa.sh managed              # switch back to managed mode
./alfa.sh stop                 # shut down VM (auto-disables proxy)
```

## Commands

| command | what it does |
|---|---|
| `./install.sh` | install QEMU, download Ubuntu arm64 minimal image, boot VM, build & tune driver |
| `./alfa.sh up` / `stop` | boot / power off VM (`127.0.0.1:2222`; `stop` also resets macOS proxy) |
| `./alfa.sh ssh` | shell into the VM as `alfa` (passwordless sudo) |
| `./alfa.sh driver` | build `rtl8814au` DKMS module (with Ubuntu 6.8 patch) and apply `tune` |
| `./alfa.sh tune` | apply USB 3.0, zero power-save, RX aggregation, BBR + `fq` + 16 MB TCP buffers |
| `./alfa.sh usb-on` / `usb-off` | hot-plug dongle into VM (auto re-attaches at USB 3.0 `5000M`) |
| `./alfa.sh verify` | verify USB 3.0 speed, interface, txpower, and AP scan count |
| `./alfa.sh wifi [SSID PASS\|off]` | scan (sorted by dBm), join Wi-Fi (`metric 10` default route + DNS), or disconnect |
| `./alfa.sh proxy [on\|cli\|off\|status]` | hardware-accelerated SOCKS5 proxy (`2.2 Gbps` loopback ceiling) for Mac host traffic |
| `./alfa.sh bench` | side-by-side MacBook `en0` vs Alfa RF, latency, and Cloudflare speed benchmark |
| `./alfa.sh monitor` / `managed` | single-interface mode switch |
| `./alfa.sh reset` | hard reset VM |

## Measured (real AP, same channel, Cloudflare speed test)

| path | down | up |
|---|---|---|
| MacBook Wi-Fi (en0, 802.11ax, -64 dBm) | 150 Mbps | 23 Mbps |
| **Mac via Alfa (proxy, -53 dBm)** | **207 Mbps** | **84 Mbps** |

## Auto-fallback (`watch.sh`)

`wifi.env` (gitignored) holds `SSID="..."/PASS="..."`. Load the LaunchAgent:

```bash
cp com.alfa.watch.plist.template ~/Library/LaunchAgents/com.alfa.watch.plist  # edit path first
launchctl load ~/Library/LaunchAgents/com.alfa.watch.plist
```

Every 3 s it: keeps the VM up, re-attaches USB 3.0, re-joins Wi-Fi, and flips the macOS
SOCKS proxy on when the Alfa link is up — off (MacBook Wi-Fi direct) the moment the dongle
is unplugged, the link drops, **packet loss exceeds 33% or RTT exceeds 600 ms** (active
quality probing via the Alfa interface). Logs: `/tmp/alfa-watch.log`.

## Performance optimizations (applied by `install.sh` / `tune`)

- **USB 3.0 SuperSpeed (`rtw_switch_usb_mode=1`):** upgrades the dongle from USB 2.0
  (`480 Mb/s`, `2.5 W / 500 mA`) to USB 3.0 (`5 Gb/s`, `4.32 W / 864 mA`), giving the 4×4 MIMO
  amplifiers 73% more power and 10× bus bandwidth. `usb-on` automatically handles the USB
  re-enumeration so it lands on `xhci` `5000M`.
- **Zero sleep / log overhead:** `rtw_power_mgnt=0 rtw_ips_mode=0 rtw_enusbss=0 rtw_drv_log_level=0`,
  `iw set power_save off`, `rtw_vht_enable=1` (optimal managed-mode VHT), `rtw_rx_ampdu_amsdu=1`.
- **Full 5.8 GHz UNII-3 preserved:** `rtw_country_code` is intentionally left unset because
  Realtek's internal channel-plan table disables channels 149–165 for several regions.
- **Linux TCP stack:** `tcp_bbr` + `fq` qdisc + 16 MB `rmem_max`/`wmem_max` + `tcp_fastopen=3` +
  `tcp_mtu_probing=1` + `tcp_slow_start_after_idle=0`.
- **2.2 Gbps host↔VM proxy:** `proxy` uses `ssh -D` with `-c aes128-gcm@openssh.com` (Apple
  Silicon ARMv8 hardware AES-GCM) — measured at `~2,200 Mbps` over QEMU SLIRP loopback, well
  above RTL8814AU's 1.3 Gbps PHY max.

## Using the antenna instead of MacBook Wi-Fi

1. **System-wide Mac browsers & apps (easiest):**
   ```bash
   ./alfa.sh wifi "SSID" "PASS"
   ./alfa.sh proxy on
   ```
   Enables a local SOCKS5 proxy on `127.0.0.1:1080` and points macOS Wi-Fi SOCKS settings to it.
   Run `./alfa.sh proxy off` (or `./alfa.sh stop`) to switch back.
2. **CLI / per-app only (works even with MacBook Wi-Fi turned off):**
   ```bash
   ./alfa.sh proxy cli
   ALL_PROXY=socks5h://127.0.0.1:1080 curl -s https://ifconfig.me
   ```
3. **Full L3 non-proxy traffic (UDP/VPN/all packets):** attach the dongle to a Raspberry Pi and
   NAT its Ethernet/USB-C interface to the MacBook.

## Troubleshooting

| symptom | fix |
|---|---|
| `dongle not visible to macOS` | `system_profiler SPUSBHostDataType \| grep -i 802.11` — use a USB 3.0 data cable / powered hub |
| Stuck at `480M` instead of `5000M` | run `./alfa.sh tune` or `./alfa.sh usb-on` (needs a USB 3.0 cable + USB 3.0 hub/port) |
| macOS *Accessories* prompt | System Settings → Privacy & Security → Allow accessories to connect |
| `dkms build error ... incompatible-pointer-types` | rerun `./alfa.sh driver` (applies the Ubuntu 6.8 `set_monitor_channel` patch) |
| Guest wedged after mode switch | `./alfa.sh reset`, then use `./alfa.sh monitor` / `managed` (never add a second `mon0`) |
| Mac browser has no internet after killing QEMU manually | run `./alfa.sh proxy off` |

## Notes / limits

- Tested on Apple Silicon macOS, QEMU 10/11, Ubuntu 24.04 minimal arm64 (kernel 6.8), Alfa AWUS1900
  (including through a USB-C 3.1 hub).
- All generated artifacts (`*.qcow2`, `*.iso`, `vars.fd`, `id_ed25519*`, `*.pid`, `*.log`) are gitignored.

MIT licensed.
