# Changelog

## 2026-11-22 (5) — Rename `watch.sh` → `alfa-autoswitch.sh` + `AlfaBar` TUI shortcut
- Renamed `watch.sh` → `alfa-autoswitch.sh` and LaunchAgent `com.alfa.watch` → `com.alfa.autoswitch` (log `/tmp/alfa-autoswitch.log`) for clarity.
- Added **Open TUI (`alfa`)** item to `AlfaBar` and removed remaining auto-scan trigger on status poll so menu bar status + terminal TUI work side by side with zero radio disruption.

## 2026-11-22 (4) — Reliability overhaul + `alfa` CLI TUI
- **New `alfa` CLI TUI (`alfa-tui.py`)**: zero-dependency Python `curses` terminal controller installed globally as `alfa` (`[s]` start, `[x]` stop, `[c]` live scan & connect with hidden password prompt, `[d]` disconnect, `[a]`/`[m]` switch Alfa/MacBook, `[w]` toggle auto-watch, `[u]` re-attach USB, `[b]` speed test, `[l]` watch log). Direct CLI passthrough (`alfa status`, `alfa start`, `alfa stop`, etc.).
- **Fix: QEMU & SSH proxy killed by `SIGHUP`** — QEMU overrides `SIG_IGN` set by `nohup`, causing silent shutdowns when parent shells/subprocesses exit. Added `daemonize()` (`fork()` + `POSIX::setsid()` before `exec`) in `alfa.sh` for both QEMU and SSH SOCKS5.
- **Fix: `watch.sh` cutting off active downloads** — replaced aggressive single-probe RTT/loss fallback (which triggered on normal Wi-Fi bufferbloat during downloads) with hysteresis (3 consecutive 100%-loss probes) and 5 s loop cadence.
- **Fix: `watch.sh` & LaunchAgent `PATH` / stale proxy / lock races** — added `/opt/homebrew/bin` to `PATH` in scripts and `com.alfa.watch.plist.template`; `stop` and `watch.sh` always inspect & clear stuck macOS SOCKS proxy even without PID/state files; added `/tmp/alfa-mode` (manual off respected by watch), `/tmp/alfa-op.pid` lock, `usb-off` on unplug (stops `libusb` log spam), and in-range check before auto-joining saved SSID.
- **Fix: `alfa.sh` scan, status, quoting & routing** — added `alfa start`, `alfa status`, and `alfa scan` (with `iw scan dump` fallback when `wpa_supplicant` holds the radio busy `-16`), safe `wpa_supplicant` escaping, credential persistence to `wifi.env` on successful join, and clean single `metric 10` default route.
- **Fix: `AlfaBar` (`main.swift`)** — moved all polling/curl/actions off main thread, fixed `MHz ` SSID parsing bug, removed destructive 30 s background `iw scan` (which stalled RTL8814AU links), made `VM` path portable, added `NSApp.activate` + `NSSecureTextField` for password dialogs.
- **Verified live**: uninterrupted 10 MB Cloudflare download over Alfa SOCKS5 at `9.0 Mbps` vs MacBook `en0` `4.3 Mbps` (>2× faster, 0% drops on 5 GHz `-72 dBm`).

## 2026-11-22 (3)
- **AlfaBar**: background scan cache (32 s scan froze the menu), spaced-SSID parsing, per-SSID password (was reusing wifi.env for any network), ✅/❌ join alert, Stop VM item.
- **Fix**: DKMS rebuild for kernel 6.8.0-149 (Ubuntu auto-update orphaned the module) — `driver` now rebuilds for any new kernel via dkms add/build/install.

## 2026-11-22 (2)
- **Fix: VM failed to boot after Mac reboot** — bash 3.2 treats empty array expansion as unbound; guard `${usb_dev[@]+...}` added.
- **AlfaBar: "Join network…"** — live scan submenu, click SSID to join (saved password from `wifi.env`, else prompt). Switch networks entirely from the menu bar.

## 2026-11-22 — d6b8a99+
- **AlfaBar.app**: menu bar status (📡 via Alfa / ◎ MacBook Wi-Fi), dongle+watch state, exit IP, force-on/off, rescan, auto-start at login. `./build-alfabar.sh` (needs Xcode CLT).
- **Quality-based fallback** (`watch.sh`): active ping probe through the Alfa interface; fallback if loss >33% or RTT >600 ms.
- `iputils-ping` added to VM packages (Ubuntu minimal lacked it — broke Alfa ping/bench).

## 2026-11-20
- **b328fcc**: auto-fallback `watch.sh` + LaunchAgent, 5 GHz-preferred join, real-world benchmark (Alfa 207/84 Mbps vs MacBook 150/23).
- **b49daa3**: max tuning — USB 3.0 SuperSpeed auto-attach (5 Gb/s, 4.32 W), zero power-save/log, RX AMPDU+AMSDU, BBR+fq+16 MB buffers, KE regdom fix (UNII-3 30 dBm), 2.2 Gbps aes128-gcm SOCKS5 proxy, `bench` command.
- **bbfe025**: initial — headless QEMU/HVF VM, Ubuntu 24.04 minimal arm64, cloud-init, USB passthrough, morrownr/8814au DKMS with Ubuntu 6.8 `set_monitor_channel` patch.
