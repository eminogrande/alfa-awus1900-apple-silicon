# Changelog

## 2026-11-22 — d6b8a99+
- **AlfaBar.app**: menu bar status (📡 via Alfa / ◎ MacBook Wi-Fi), dongle+watch state, exit IP, force-on/off, rescan, auto-start at login. `./build-alfabar.sh` (needs Xcode CLT).
- **Quality-based fallback** (`watch.sh`): active ping probe through the Alfa interface; fallback if loss >33% or RTT >600 ms.
- `iputils-ping` added to VM packages (Ubuntu minimal lacked it — broke Alfa ping/bench).

## 2026-11-20
- **b328fcc**: auto-fallback `watch.sh` + LaunchAgent, 5 GHz-preferred join, real-world benchmark (Alfa 207/84 Mbps vs MacBook 150/23).
- **b49daa3**: max tuning — USB 3.0 SuperSpeed auto-attach (5 Gb/s, 4.32 W), zero power-save/log, RX AMPDU+AMSDU, BBR+fq+16 MB buffers, KE regdom fix (UNII-3 30 dBm), 2.2 Gbps aes128-gcm SOCKS5 proxy, `bench` command.
- **bbfe025**: initial — headless QEMU/HVF VM, Ubuntu 24.04 minimal arm64, cloud-init, USB passthrough, morrownr/8814au DKMS with Ubuntu 6.8 `set_monitor_channel` patch.
