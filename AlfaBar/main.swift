// AlfaBar — minimal menu bar status for the Alfa AWUS1900 VM (Swift 6, AppKit only).
import AppKit

let VM = "/Users/eminmahrt/Developer/alfa-vm"
let STATE = "/tmp/alfa-watch.state"
let LOG = "/tmp/alfa-watch.log"

func read(_ p: String) -> String {
  (try? String(contentsOfFile: p, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
func shell(_ cmd: String) -> String {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/bash")
  p.arguments = ["-c", cmd]
  let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
  try? p.run(); p.waitUntilExit()
  return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var item: NSStatusItem!
  var menu: NSMenu!
  var stateLine: NSMenuItem!
  var detail: NSMenuItem!
  var ipLine: NSMenuItem!
  var timer: Timer!
  var joinItem: NSMenuItem!

  func applicationDidFinishLaunching(_ n: Notification) {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    menu = NSMenu()
    stateLine = menu.addItem(withTitle: "…", action: nil, keyEquivalent: "")
    stateLine.isEnabled = false
    detail = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
    detail.isEnabled = false
    ipLine = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
    ipLine.isEnabled = false
    menu.addItem(.separator())
    joinItem = menu.addItem(withTitle: "Join network…", action: nil, keyEquivalent: "")
    joinItem.submenu = NSMenu()
    joinItem.submenu!.delegate = self
    menu.addItem(withTitle: "Force Alfa (proxy on)", action: #selector(forceOn), keyEquivalent: "a").target = self
    menu.addItem(withTitle: "Force MacBook Wi-Fi (proxy off)", action: #selector(forceOff), keyEquivalent: "m").target = self
    menu.addItem(withTitle: "Stop VM (full off)", action: #selector(stopVM), keyEquivalent: "x").target = self
    menu.addItem(withTitle: "Rescan now", action: #selector(rescan), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Toggle watch", action: #selector(toggleWatch), keyEquivalent: "w").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Open VM shell", action: #selector(shellVM), keyEquivalent: "s").target = self
    menu.addItem(withTitle: "GitHub repo", action: #selector(repo), keyEquivalent: "g").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = menu
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.refresh() }
    scanWifi()
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.scanWifi() }
  }

  func refresh() {
    let on = read(STATE) == "on"
    item.button?.title = on ? "📡" : "◎"
    let dongle = shell("ioreg -p IOUSB -w0 | grep -c '802.11ac NIC'") == "1"
    let ip = shell("curl -s --max-time 4 https://ifconfig.me || echo ?")
    stateLine.title = on ? "🟢 via Alfa antenna" : "⚪︎ via MacBook Wi-Fi"
    detail.title = "dongle: \(dongle ? "plugged (USB 3.0)" : "unplugged") · watch: \(shell("pgrep -f watch.sh >/dev/null && echo on || echo off"))"
    ipLine.title = "IP: \(ip)"
  }

  var ssids: [String] = []
  func scanWifi() {
    DispatchQueue.global().async {
      let out = shell(VM + #"/alfa.sh wifi 2>/dev/null | awk '{$1=$2=$3=""; sub(/^ +/,""); print}' | grep -v 'dBm\|SSID\|^$' | awk 'NF' | sort -u | head -12"#)
      let list = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
      DispatchQueue.main.async { self.ssids = list }
    }
  }
  func menuNeedsUpdate(_ m: NSMenu) {
    m.removeAllItems()
    guard !ssids.isEmpty else { let i = m.addItem(withTitle: "(scanning… give it 30 s)", action: nil, keyEquivalent: ""); i.isEnabled = false; return }
    for ssid in ssids {
      let it = m.addItem(withTitle: ssid, action: #selector(join(_:)), keyEquivalent: "")
      it.target = self; it.representedObject = ssid
    }
  }
  @objc func join(_ sender: NSMenuItem) {
    guard let ssid = sender.representedObject as? String else { return }
    let saved = shell(". \(VM)/wifi.env 2>/dev/null; [ \"${SSID:-}\" = \"\(ssid)\" ] && echo \"${PASS:-}\"")
    var pass = saved
    if pass.isEmpty {
      let a = NSAlert(); a.messageText = "Wi-Fi password for \"\(ssid)\""; a.addButton(withTitle: "Join"); a.addButton(withTitle: "Cancel")
      let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); a.accessoryView = f; a.window.initialFirstResponder = f
      if a.runModal() == .alertFirstButtonReturn { pass = f.stringValue } else { return }
    }
    DispatchQueue.global().async {
      let r = shell("\(VM)/alfa.sh wifi \"\(ssid)\" \"\(pass)\" 2>/dev/null | grep -c \"Connected to\"")
      DispatchQueue.main.async {
        self.refresh()
        let a = NSAlert(); a.messageText = r == "1" ? "✅ Joined \"\(ssid)\" via Alfa" : "❌ Failed to join \"\(ssid)\" (wrong password?)"
        a.runModal()
      }
    }
  }
  @objc func stopVM() { DispatchQueue.global().async { _ = shell("\(VM)/alfa.sh stop") } }
  @objc func forceOn() { shell("\(VM)/alfa.sh proxy on") }
  @objc func forceOff() { shell("\(VM)/alfa.sh proxy off") }
  @objc func rescan() {
    shell("\(VM)/alfa.sh usb-on")
    shell(". \(VM)/wifi.env 2>/dev/null; [ -n \"$SSID\" ] && \(VM)/alfa.sh wifi \"$SSID\" \"$PASS\"")
  }
  @objc func toggleWatch() { shell("launchctl kickstart -k gui/$(id -u)/com.alfa.watch") }
  @objc func shellVM() { shell("open -a Terminal \(VM)") }
  @objc func repo() { NSWorkspace.shared.open(URL(string: "https://github.com/eminogrande/alfa-awus1900-apple-silicon")!) }
}

let app = NSApplication.shared
let d = AppDelegate()
app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
