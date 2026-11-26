# Alfa AWUS1900 (RTL8814AU) on Apple Silicon macOS

Realtek never shipped an arm64 macOS driver for the RTL8814AU (Alfa AWUS1900 / AWUS036ACH family, `0bda:8813`). macOS sees the dongle on USB but creates no network interface.

This repo runs the dongle inside a **headless Linux VM** (QEMU + Apple `hvf` + USB 3.0 SuperSpeed passthrough + tuned `morrownr/8814au` DKMS driver + `aes128-gcm` SOCKS5 proxy) controlled by a **zero-dependency terminal TUI (`alfa`)**, an optional **menu bar status app (`AlfaBar`)**, and an automatic fallback daemon (`alfa-autoswitch.sh`). No GUI VM app, no UTM, ~512 MB RAM, boots in ~8 s.

## Quick start

```bash
git clone https://github.com/eminogrande/alfa-awus1900-apple-silicon.git
cd alfa-awus1900-apple-silicon
./install.sh
```

`install.sh` installs QEMU, downloads Ubuntu 24.04 minimal arm64, builds & tunes the `rtl8814au` DKMS module, and installs the global `alfa` command in `$(brew --prefix)/bin/alfa`.

Then run the interactive TUI from any terminal:

```bash
alfa
```

### TUI controls (`alfa`)

| key | action |
|---|---|
| `s` | **Start Alfa** — boot VM, attach USB 3.0, join saved Wi-Fi, enable proxy |
| `x` | **Stop Alfa** — disable macOS proxy, shut down VM, pause auto-watch |
| `c` | **Connect Wi-Fi** — live scan picker (↑/↓ + Enter), hidden SSID option, hidden password input, saves to `wifi.env` |
| `d` | **Disconnect Wi-Fi** — disconnect Alfa and fall back to MacBook Wi-Fi |
| `a` / `m` | **Use Alfa (Proxy ON)** / **Use MacBook Wi-Fi (Proxy OFF)** |
| `w` | **Toggle Auto-switch** — start/stop `com.alfa.autoswitch` LaunchAgent |
| `u` | **Re-attach USB** — hot-plug/re-enumerate dongle at USB 3.0 (`5000M`) |
| `b` | **Speed test** — 5 MB Cloudflare download, Alfa SOCKS5 vs MacBook direct |
| `l` | **Auto-switch log** — inspect `/tmp/alfa-autoswitch.log` |
| `q` | **Quit TUI** — leaves VM, proxy, and auto-switch running in background |

## Direct CLI commands

Any argument passed to `alfa` (or `./alfa.sh`) runs directly without opening the TUI:

| command | what it does |
|---|---|
| `alfa start` | one-shot boot VM + attach USB + join saved `wifi.env` + proxy on |
| `alfa up` / `stop` | boot / cleanly power off VM (`stop` always resets macOS SOCKS proxy) |
| `alfa status` | machine-readable live state (`dongle`, `vm`, `iface`, `ssid`, `signal`, `proxy`, `sys_proxy`, `watch`, `mode`) |
| `alfa scan` | deduplicated tab-separated Wi-Fi scan (`SSID`, `dBm`, `MHz`) with `scan dump` fallback |
| `alfa wifi [SSID PASS\|off]` | scan, join Wi-Fi (prefers 5 GHz, sets `metric 10` default route + DNS, saves `wifi.env`), or disconnect |
| `alfa proxy [on\|cli\|off\|status]` | hardware-accelerated `aes128-gcm` SOCKS5 proxy on `127.0.0.1:1080` |
| `alfa usb-on` / `usb-off` | hot-plug / detach dongle on QEMU `xhci` bus |
| `alfa bench` | side-by-side MacBook `en0` vs Alfa RF, latency, and Cloudflare speed benchmark |
| `alfa ssh` | shell into the VM as `alfa` (passwordless sudo) |
| `alfa driver` / `tune` | rebuild DKMS driver (with Ubuntu 6.8 patch) / reapply USB 3.0 + BBR tuning |
| `alfa monitor` / `managed` | single-interface mode switch |
| `alfa reset` | hard reset VM |

## Measured performance

- **Strong 5 GHz AP (same channel, Cloudflare 25 MB / 5 MB):**
  - MacBook `en0` (802.11ax, -64 dBm): `150 Mbps` down / `23 Mbps` up
  - **Mac via Alfa (`127.0.0.1:1080`, -53 dBm): `207 Mbps` down / `84 Mbps` up**
- **Weak / distant 5 GHz AP (-72 dBm, Cloudflare 10 MB uninterrupted):**
  - MacBook `en0`: `4.3 Mbps`
  - **Mac via Alfa: `9.0 Mbps`** (>2× faster, 0% drops)

## Auto-switch daemon (`alfa-autoswitch.sh`)

Install the LaunchAgent once (replaces `__DIR__` with your repo path):

```bash
sed "s|__DIR__|$PWD|g" com.alfa.autoswitch.plist.template > ~/Library/LaunchAgents/com.alfa.autoswitch.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.alfa.autoswitch.plist
```

How `alfa-autoswitch.sh` behaves:
- **Always default when ON:** when the dongle is plugged in and Alfa is ON (`/tmp/alfa-mode != off`), auto-boots VM, attaches USB 3.0, rejoins saved `wifi.env` (auto-resetting USB after failed joins), and enables macOS SOCKS5 proxy across all active physical network services (`Wi-Fi`, `iPhone USB`, USB Ethernet) — never dropping Alfa for ping spikes or load.
- **Open Speedify handoff:** detects active Open Speedify (`127.0.0.1:19454`), yields system SOCKS5 cleanly while Open Speedify bonds Alfa with other links, and immediately restores Alfa as default when Open Speedify stops.
- **Unplug or manual OFF:** immediately clears macOS system SOCKS5 across all services so MacBook Wi-Fi keeps working seamlessly, detaches QEMU USB on unplug, and stops cleanly when turned OFF.
- **Op lock (`/tmp/alfa-op.pid`):** skips loop ticks while an interactive `alfa` command is running.

---

## Guide & Lessons Learned (for anyone building this on Apple Silicon)

If you're passing a USB Wi-Fi adapter (especially Realtek `8814au` / `8812au`) into QEMU on Apple Silicon macOS, these are the non-obvious traps that make naive setups unreliable — and how this repo fixes each one:

1. **`nohup qemu-system-aarch64 ... &` STILL dies on `SIGHUP`!**
   QEMU installs its own `SIGHUP` handler that **overwrites** `SIG_IGN` set by `nohup`. When a parent script, Terminal tab, or GUI subprocess exits, macOS sends `SIGHUP` to the process group and QEMU shuts down (`terminating on signal 1`).
   - *Fix:* fork and call `POSIX::setsid()` **before** `exec`ing QEMU (and SSH proxy), via macOS's built-in `/usr/bin/perl` (`daemonize()` in `alfa.sh`). Avoids both `SIGHUP` and macOS CoreFoundation post-init `fork()` hazards.

2. **LaunchAgents and macOS GUI apps don't have `/opt/homebrew/bin` in `PATH`.**
   Scripts that work fine in your interactive zsh shell fail silently under `launchd` because `qemu-system-aarch64` lives in `/opt/homebrew/bin`.
   - *Fix:* export `PATH="/opt/homebrew/bin:/usr/local/bin:..."` at the top of `alfa.sh` and `alfa-autoswitch.sh`, and set `EnvironmentVariables.PATH` in `com.alfa.autoswitch.plist`.

3. **Never poll `iw dev <if> scan` in the background while associated on Realtek `8814au`.**
   Periodic active off-channel scans (e.g. a menu bar app scanning every 30 s) stall or briefly drop the active 5 GHz link (`linkdown`) and kill throughput. Also, when `wpa_supplicant` is scanning, `iw scan` returns `-16 (EBUSY)`.
   - *Fix:* only scan on demand (when you open the Wi-Fi picker), and fall back to `iw dev <if> scan dump` when `iw scan` returns busy.

4. **Don't kill a SOCKS proxy on a single ping RTT spike.**
   Under full download saturation, Wi-Fi bufferbloat routinely pushes ICMP RTT past 600 ms or drops 1 of 3 pings. A watchdog that immediately kills the proxy on one slow ping will sever every active download/stream mid-flight.
   - *Fix:* require 3 consecutive 100%-loss probes before falling back to MacBook Wi-Fi.

5. **Stale macOS SOCKS proxy breaks all Mac internet after crashes/reboots.**
   If QEMU or SSH dies unexpectedly, macOS keeps `127.0.0.1:1080` enabled on `Wi-Fi` forever.
   - *Fix:* `alfa stop` always runs `proxy_off` regardless of PID files, kills any orphaned `ssh -D 127.0.0.1:1080`, and `alfa-autoswitch.sh` checks live `networksetup -getsocksfirewallproxy Wi-Fi` state (not just a `/tmp` state file that disappears on reboot).

6. **USB 3.0 mode-switching (`rtw_switch_usb_mode=1`) re-enumerates the dongle.**
   RTL8814AU boots in USB 2.0 (`480M`, 2.5 W). Enabling `rtw_switch_usb_mode=1` resets it onto the USB 3.0 bus (`5000M`, 4.32 W — 73% more power for the 4×4 MIMO amps), which disconnects it from QEMU's `usb-host` handle once.
   - *Fix:* `usb_attach` automatically re-attaches via QEMU monitor (`device_del` / `device_add`) until `lsusb -t` shows `rtl8814au, 5000M`.

7. **Avoid duplicate default routes and Ubuntu 6.8 DKMS breaks.**
   - `dhclient` installs a metric-0 default route; delete it before replacing with `metric 10` so `enp0s3` (QEMU NAT, `metric 100`) stays cleanly as fallback.
   - Ubuntu 24.04's 6.8 kernel backports the 3-arg `cfg80211` `set_monitor_channel`; `alfa driver` patches the kernel-version guard from `6.12.101` to `6.8.0`.
   - Leave `rtw_country_code` unset — Realtek's internal table disables 5.8 GHz UNII-3 channels (149–165) in several regions.

## AlfaBar menu bar app

Native Swift/AppKit emoji menu bar controller (`⚪ 📡` / `🟡 📡` / `🟢 📡`) with a single **🟢 Turn Alfa ON / 🔴 Turn Alfa OFF** toggle and Wi-Fi picker (`./build-alfabar.sh`, installs `com.alfabar` LaunchAgent).

## Troubleshooting

| symptom | fix |
|---|---|
| `dongle not visible to macOS` | `ioreg -p IOUSB -w0 \| grep '802.11ac'` — check USB 3.0 data cable / powered hub |
| Stuck at `480M` instead of `5000M` | run `alfa tune` or `alfa usb-on` (needs USB 3.0 cable + port) |
| macOS *Accessories* prompt | System Settings → Privacy & Security → Allow accessories to connect |
| `dkms build error` after kernel update | run `alfa driver` |
| Mac browser has no internet after manual kill | run `alfa proxy off` |
| Full L3 non-proxy traffic (UDP / VPN) | SOCKS5 covers TCP/browsers/CLI; for full L3 NAT, attach the dongle to a Raspberry Pi over USB-C/Ethernet |

MIT licensed.
