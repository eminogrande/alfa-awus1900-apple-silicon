#!/usr/bin/env python3
"""Alfa TUI — fast, zero-dependency terminal controller for Alfa AWUS1900 VM."""
import curses
import os
import subprocess
import sys
import threading
import time

VM_DIR = os.environ.get("ALFA_DIR") or os.path.dirname(os.path.realpath(__file__))
ALFA_SH = os.path.join(VM_DIR, "alfa.sh")
MODE_FILE = "/tmp/alfa-mode"
LOG_FILE = "/tmp/alfa-watch.log"
WATCH_PLIST = os.path.expanduser("~/Library/LaunchAgents/com.alfa.watch.plist")
ENV = {**os.environ, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}


def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV, timeout=timeout)
        return p.returncode, (p.stdout or "").strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except Exception as e:
        return 1, str(e)


def run_alfa(*args, timeout=60):
    return run(["/bin/bash", ALFA_SH, *args], timeout=timeout)


def parse_status(raw):
    d = {
        "dongle": False, "vm": False, "iface": "", "ssid": "",
        "freq": "", "signal": "", "ip": "", "proxy": False,
        "sys_proxy": False, "watch": False, "mode": "auto",
    }
    for line in raw.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k in ("dongle", "vm", "proxy", "sys_proxy", "watch"):
            d[k] = (v == "1")
        elif k in d:
            d[k] = v
    d["routing"] = d["sys_proxy"] and d["proxy"] and bool(d["ssid"])
    return d


def saved_pass(ssid):
    cmd = f'. "{VM_DIR}/wifi.env" 2>/dev/null || exit 1; [ "${{SSID:-}}" = "$1" ] && printf "%s" "${{PASS:-}}"'
    code, out = run(["/bin/bash", "-c", cmd, "_", ssid], timeout=5)
    return out if code == 0 else None


def safe_add(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if y < 0 or y >= h or x >= w:
        return
    try:
        win.addnstr(y, x, text, max(0, w - x - 1), attr)
    except curses.error:
        pass


class AlfaTUI:
    def __init__(self):
        self.lock = threading.Lock()
        self.status = parse_status("")
        self.exit_ip = "…"
        self.busy = None
        self.msg = "Ready."
        self.stop_evt = threading.Event()
        self.last_ip_t = 0.0
        self.last_route = None

    def refresh_once(self):
        _, out = run_alfa("status", timeout=8)
        st = parse_status(out)
        with self.lock:
            route_changed = (self.last_route != st["routing"])
            self.last_route = st["routing"]
            self.status = st
            need_ip = route_changed or (time.time() - self.last_ip_t > 15)
        if need_ip:
            args = ["/usr/bin/curl", "-s", "--max-time", "3"]
            args += ["--socks5-hostname", "127.0.0.1:1080"] if st["routing"] else ["--noproxy", "*"]
            args.append("https://ifconfig.me")
            code, ip = run(args, timeout=5)
            with self.lock:
                self.exit_ip = ip if (code == 0 and ip and len(ip) < 64) else "offline"
                self.last_ip_t = time.time()

    def poll_loop(self):
        while not self.stop_evt.is_set():
            self.refresh_once()
            self.stop_evt.wait(3.0)

    def start_op(self, label, fn):
        with self.lock:
            if self.busy:
                self.msg = f"Busy: {self.busy}"
                return
            self.busy = label
            self.msg = label

        def worker():
            try:
                res = fn()
            except Exception as e:
                res = f"Error: {e}"
            self.refresh_once()
            with self.lock:
                self.busy = None
                self.msg = res or "Done."

        threading.Thread(target=worker, daemon=True).start()

    def prompt_text(self, scr, title, prompt, secret=False):
        curses.curs_set(1)
        buf = []
        while True:
            scr.erase()
            safe_add(scr, 1, 2, title, curses.A_BOLD)
            safe_add(scr, 3, 2, prompt)
            shown = ("*" * len(buf)) if secret else "".join(buf)
            safe_add(scr, 5, 2, f"> {shown}", curses.A_REVERSE)
            safe_add(scr, 7, 2, "Enter = confirm   Esc = cancel", curses.A_DIM)
            scr.refresh()
            ch = scr.getch()
            if ch in (27,):  # Esc
                curses.curs_set(0)
                return None
            if ch in (10, 13, curses.KEY_ENTER):
                curses.curs_set(0)
                return "".join(buf)
            if ch in (curses.KEY_BACKSPACE, 127, 8):
                if buf:
                    buf.pop()
            elif 32 <= ch <= 126:
                buf.append(chr(ch))

    def connect_flow(self, scr):
        with self.lock:
            st = dict(self.status)
        if not st["vm"]:
            with self.lock:
                self.msg = "Start VM first ([s])."
            return
        if not st["dongle"] or not st["iface"]:
            with self.lock:
                self.msg = "Dongle not attached (plug in or press [u])."
            return

        scr.nodelay(False)
        scr.erase()
        safe_add(scr, 1, 2, "Scanning Wi-Fi networks via Alfa…", curses.A_BOLD)
        scr.refresh()
        _, raw = run_alfa("scan", timeout=20)
        nets = []
        for line in raw.splitlines():
            cols = line.split("\t")
            if cols and cols[0]:
                sig = cols[1] if len(cols) > 1 else ""
                freq = cols[2] if len(cols) > 2 else ""
                band = "5 GHz" if freq.startswith("5") else ("2.4 GHz" if freq.startswith("2") else "")
                nets.append((cols[0], sig, band))

        items = [(f"{n[0]}  ({n[1]} dBm · {n[2]})", n[0]) for n in nets]
        items.append(("[Other / hidden network…]", None))
        idx = 0
        while True:
            scr.erase()
            safe_add(scr, 1, 2, "Connect Alfa to Wi-Fi", curses.A_BOLD)
            safe_add(scr, 2, 2, "↑/↓ select   Enter connect   r rescan   Esc back", curses.A_DIM)
            for i, (label, ssid) in enumerate(items):
                mark = "✓ " if (ssid and ssid == st["ssid"]) else "  "
                attr = curses.A_REVERSE if i == idx else 0
                safe_add(scr, 4 + i, 2, f"{mark}{label}", attr)
            scr.refresh()
            ch = scr.getch()
            if ch in (27, ord("q")):
                scr.nodelay(True)
                return
            if ch in (curses.KEY_UP, ord("k")) and idx > 0:
                idx -= 1
            elif ch in (curses.KEY_DOWN, ord("j")) and idx < len(items) - 1:
                idx += 1
            elif ch == ord("r"):
                scr.nodelay(True)
                self.connect_flow(scr)
                return
            elif ch in (10, 13, curses.KEY_ENTER):
                chosen = items[idx][1]
                if chosen is None:
                    chosen = self.prompt_text(scr, "Connect to hidden/custom Wi-Fi", "Network SSID:")
                    if not chosen:
                        scr.nodelay(True)
                        return
                pw = saved_pass(chosen)
                if pw is None:
                    pw = self.prompt_text(scr, f"Password for \"{chosen}\"", "Enter password (blank for open):", secret=True)
                    if pw is None:
                        scr.nodelay(True)
                        return
                scr.nodelay(True)

                def do_join(s=chosen, p=pw):
                    with open(MODE_FILE, "w") as f:
                        f.write("auto\n")
                    code, out = run_alfa("wifi", s, p, timeout=45)
                    if code != 0:
                        last = out.splitlines()[-1] if out else "failed"
                        return f"Join '{s}' failed: {last}"
                    pcode, pout = run_alfa("proxy", "on", timeout=15)
                    if pcode != 0:
                        return f"Joined '{s}', proxy error: {pout}"
                    return f"Connected to '{s}' & routing via Alfa."

                self.start_op(f"Joining {chosen}…", do_join)
                return

    def show_log(self, scr):
        scr.nodelay(False)
        while True:
            scr.erase()
            safe_add(scr, 1, 2, f"Watch Log ({LOG_FILE})   [r] refresh   [Esc/q] back", curses.A_BOLD)
            lines = []
            if os.path.exists(LOG_FILE):
                with open(LOG_FILE, errors="replace") as f:
                    lines = f.read().splitlines()
            h, _ = scr.getmaxyx()
            for i, line in enumerate(lines[-(h - 4):]):
                safe_add(scr, 3 + i, 2, line)
            scr.refresh()
            ch = scr.getch()
            if ch in (27, ord("q")):
                break
        scr.nodelay(True)

    def draw(self, scr):
        scr.erase()
        with self.lock:
            st = dict(self.status)
            ip = self.exit_ip
            busy = self.busy
            msg = self.msg

        green = curses.color_pair(1) | curses.A_BOLD
        yellow = curses.color_pair(2) | curses.A_BOLD
        red = curses.color_pair(3) | curses.A_BOLD
        cyan = curses.color_pair(4) | curses.A_BOLD

        safe_add(scr, 1, 2, "ALFA AWUS1900 CONTROLLER", cyan)
        safe_add(scr, 2, 2, "─" * 54, curses.A_DIM)

        if busy:
            safe_add(scr, 3, 2, f"⏳ {busy}", yellow)
        elif st["routing"]:
            safe_add(scr, 3, 2, "● ROUTING VIA ALFA ANTENNA", green)
        elif st["vm"] and st["ssid"]:
            safe_add(scr, 3, 2, "◐ ALFA CONNECTED (MacBook Wi-Fi active)", yellow)
        else:
            safe_add(scr, 3, 2, "○ MACBOOK WI-FI (direct)", yellow)

        dongle_txt = "Plugged" if st["dongle"] else "Unplugged"
        vm_txt = "Running" if st["vm"] else "Stopped"
        safe_add(scr, 5, 2, f"Dongle : {dongle_txt:<12}  VM     : {vm_txt}", green if st["dongle"] else red)

        if st["ssid"]:
            band = "5 GHz" if st["freq"].startswith("5") else ("2.4 GHz" if st["freq"].startswith("2") else "")
            wifi_txt = f"{st['ssid']}  ({st['signal']} dBm · {band} · {st['ip']})"
        elif st["iface"]:
            wifi_txt = f"Disconnected ({st['iface']})"
        else:
            wifi_txt = "No Wi-Fi interface"
        safe_add(scr, 6, 2, f"Wi-Fi  : {wifi_txt}")

        prx_txt = "ON (127.0.0.1:1080)" if st["proxy"] else "OFF"
        sys_txt = "ON" if st["sys_proxy"] else "OFF"
        safe_add(scr, 7, 2, f"Proxy  : SOCKS5 {prx_txt}  ·  macOS System: {sys_txt}")

        w_txt = "OFF"
        if st["watch"]:
            w_txt = "PAUSED (manual off)" if st["mode"] == "off" else "ON (auto-fallback)"
        safe_add(scr, 8, 2, f"Watch  : {w_txt:<22}  Exit IP: {ip}")

        safe_add(scr, 10, 2, "─" * 54, curses.A_DIM)
        safe_add(scr, 11, 2, "[s] Start Alfa (VM+USB+Wi-Fi+Proxy)   [x] Stop Alfa")
        safe_add(scr, 12, 2, "[c] Connect Wi-Fi (scan & join)       [d] Disconnect Wi-Fi")
        safe_add(scr, 13, 2, "[a] Use Alfa (Proxy ON)               [m] Use MacBook Wi-Fi")
        safe_add(scr, 14, 2, "[w] Toggle Auto-watch                 [u] Re-attach USB")
        safe_add(scr, 15, 2, "[b] Speed test (Alfa vs MacBook)      [l] View Watch Log")
        safe_add(scr, 16, 2, "[r] Refresh                           [q] Quit TUI")

        safe_add(scr, 18, 2, "─" * 54, curses.A_DIM)
        safe_add(scr, 19, 2, f"Status: {msg}", curses.A_BOLD)
        scr.refresh()

    def run_curses(self, scr):
        curses.curs_set(0)
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, curses.COLOR_YELLOW, -1)
        curses.init_pair(3, curses.COLOR_RED, -1)
        curses.init_pair(4, curses.COLOR_CYAN, -1)
        scr.nodelay(True)
        scr.timeout(200)

        t = threading.Thread(target=self.poll_loop, daemon=True)
        t.start()

        while True:
            self.draw(scr)
            ch = scr.getch()
            if ch == -1:
                continue
            if ch in (ord("q"), ord("Q")):
                break
            elif ch == ord("r"):
                self.start_op("Refreshing…", lambda: "Refreshed.")
            elif ch == ord("s"):
                def do_start():
                    code, out = run_alfa("start", timeout=90)
                    last = out.splitlines()[-1] if out else ("Started." if code == 0 else "Failed.")
                    return last
                self.start_op("Starting Alfa (VM + USB + Wi-Fi + Proxy)…", do_start)
            elif ch == ord("x"):
                self.start_op("Stopping VM & clearing proxy…", lambda: run_alfa("stop", timeout=20)[1] or "Stopped.")
            elif ch == ord("c"):
                self.connect_flow(scr)
            elif ch == ord("d"):
                def do_disc():
                    with open(MODE_FILE, "w") as f:
                        f.write("off\n")
                    run_alfa("proxy", "off", timeout=10)
                    run_alfa("wifi", "off", timeout=15)
                    return "Disconnected Wi-Fi (MacBook direct)."
                self.start_op("Disconnecting Wi-Fi…", do_disc)
            elif ch == ord("a"):
                def do_on():
                    with open(MODE_FILE, "w") as f:
                        f.write("auto\n")
                    code, out = run_alfa("proxy", "on", timeout=15)
                    return "Routing via Alfa." if code == 0 else (out.splitlines()[-1] if out else "Failed.")
                self.start_op("Enabling Alfa proxy…", do_on)
            elif ch == ord("m"):
                def do_off():
                    with open(MODE_FILE, "w") as f:
                        f.write("off\n")
                    run_alfa("proxy", "off", timeout=10)
                    return "Switched to MacBook Wi-Fi."
                self.start_op("Switching to MacBook Wi-Fi…", do_off)
            elif ch == ord("w"):
                with self.lock:
                    active = self.status["watch"] and self.status["mode"] != "off"
                def do_watch(was_on=active):
                    uid = str(os.getuid())
                    if was_on:
                        with open(MODE_FILE, "w") as f:
                            f.write("off\n")
                        run(["/bin/launchctl", "bootout", f"gui/{uid}/com.alfa.watch"], timeout=5)
                        run(["/usr/bin/pkill", "-f", "alfa-vm/watch.sh"], timeout=5)
                        return "Auto-watch stopped."
                    else:
                        with open(MODE_FILE, "w") as f:
                            f.write("auto\n")
                        run(["/bin/launchctl", "bootout", f"gui/{uid}/com.alfa.watch"], timeout=5)
                        code, _ = run(["/bin/launchctl", "bootstrap", f"gui/{uid}", WATCH_PLIST], timeout=5)
                        if code != 0:
                            run(["/bin/launchctl", "load", "-w", WATCH_PLIST], timeout=5)
                        return "Auto-watch started."
                self.start_op("Toggling auto-watch…", do_watch)
            elif ch == ord("u"):
                self.start_op("Re-attaching USB…", lambda: run_alfa("usb-on", timeout=30)[1] or "USB attached.")
            elif ch == ord("b"):
                def do_bench():
                    _, a = run(["/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{speed_download}", "--max-time", "15", "--socks5-hostname", "127.0.0.1:1080", "https://speed.cloudflare.com/__down?bytes=5000000"], timeout=20)
                    _, m = run(["/usr/bin/curl", "--noproxy", "*", "-s", "-o", "/dev/null", "-w", "%{speed_download}", "--max-time", "15", "https://speed.cloudflare.com/__down?bytes=5000000"], timeout=20)
                    try:
                        am = float(a) * 8 / 1e6
                    except Exception:
                        am = 0.0
                    try:
                        mm = float(m) * 8 / 1e6
                    except Exception:
                        mm = 0.0
                    return f"Speed (5MB down): Alfa {am:.1f} Mbps vs MacBook {mm:.1f} Mbps"
                self.start_op("Running speed test (Alfa vs MacBook)…", do_bench)
            elif ch == ord("l"):
                self.show_log(scr)

        self.stop_evt.set()


def main():
    if len(sys.argv) > 1:
        os.execv("/bin/bash", ["/bin/bash", ALFA_SH, *sys.argv[1:]])
    tui = AlfaTUI()
    curses.wrapper(tui.run_curses)


if __name__ == "__main__":
    main()
