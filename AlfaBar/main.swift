// AlfaBar — reliable menu bar controller for Alfa AWUS1900 VM (AppKit).
import AppKit
import Foundation

let VM: String = {
  if let env = ProcessInfo.processInfo.environment["ALFA_DIR"], !env.isEmpty { return env }
  let repoDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().deletingLastPathComponent().path
  let defaultVm = NSHomeDirectory() + "/Developer/alfa-vm"
  if FileManager.default.fileExists(atPath: defaultVm + "/disk.qcow2") { return defaultVm }
  return repoDir
}()
let MODE_FILE = "/tmp/alfa-mode"
let LOG_FILE = "/tmp/alfa-watch.log"
let WATCH_PLIST = NSHomeDirectory() + "/Library/LaunchAgents/com.alfa.watch.plist"
let ENV_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

struct Status {
  var dongle = false
  var vm = false
  var iface = ""
  var ssid = ""
  var freq = ""
  var signal = ""
  var ip = ""
  var proxy = false
  var sysProxy = false
  var watch = false
  var mode = "auto"

  var routingViaAlfa: Bool { sysProxy && proxy && !ssid.isEmpty }
  var band: String {
    if freq.hasPrefix("5") { return "5 GHz" }
    if freq.hasPrefix("2") { return "2.4 GHz" }
    return ""
  }
}

struct Network {
  let ssid: String
  let signal: String
  let freq: String
  var band: String { freq.hasPrefix("5") ? "5G" : (freq.hasPrefix("2") ? "2.4G" : "") }
}

@discardableResult
func runExec(_ path: String, _ args: [String]) -> (Int32, String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: path)
  p.arguments = args
  var env = ProcessInfo.processInfo.environment
  env["PATH"] = ENV_PATH
  p.environment = env
  let out = Pipe()
  p.standardOutput = out
  p.standardError = out
  do {
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (p.terminationStatus, text)
  } catch {
    return (-1, error.localizedDescription)
  }
}

@discardableResult
func runAlfa(_ args: [String]) -> (Int32, String) {
  runExec("/bin/bash", ["\(VM)/alfa.sh"] + args)
}

func parseStatus(_ raw: String) -> Status {
  var s = Status()
  for line in raw.split(separator: "\n") {
    guard let idx = line.firstIndex(of: "=") else { continue }
    let k = String(line[..<idx])
    let v = String(line[line.index(after: idx)...])
    switch k {
    case "dongle": s.dongle = (v == "1")
    case "vm": s.vm = (v == "1")
    case "iface": s.iface = v
    case "ssid": s.ssid = v
    case "freq": s.freq = v
    case "signal": s.signal = v
    case "ip": s.ip = v
    case "proxy": s.proxy = (v == "1")
    case "sys_proxy": s.sysProxy = (v == "1")
    case "watch": s.watch = (v == "1")
    case "mode": s.mode = v.isEmpty ? "auto" : v
    default: break
    }
  }
  return s
}

func savedPassword(for ssid: String) -> String? {
  let cmd = "set -a; . \"\(VM)/wifi.env\" 2>/dev/null || exit 1; [ \"${SSID:-}\" = \"$1\" ] && printf '%s' \"${PASS:-}\""
  let (code, out) = runExec("/bin/bash", ["-c", cmd, "_", ssid])
  return code == 0 ? out : nil
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var item: NSStatusItem!
  var menu: NSMenu!
  var stateLine: NSMenuItem!
  var detailLine: NSMenuItem!
  var ipLine: NSMenuItem!
  var joinItem: NSMenuItem!
  var startItem: NSMenuItem!
  var stopItem: NSMenuItem!
  var disconnectItem: NSMenuItem!
  var useAlfaItem: NSMenuItem!
  var useMacItem: NSMenuItem!
  var watchItem: NSMenuItem!

  let pollQ = DispatchQueue(label: "com.alfabar.poll")
  let opQ = DispatchQueue(label: "com.alfabar.op")
  let scanQ = DispatchQueue(label: "com.alfabar.scan")
  let ipQ = DispatchQueue(label: "com.alfabar.ip")

  var status = Status()
  var networks: [Network] = []
  var exitIP = "…"
  var busyText: String? = nil
  var isPolling = false
  var isScanning = false
  var isFetchingIP = false
  var lastIPFetch = Date.distantPast
  var lastRouteState: Bool? = nil

  func applicationDidFinishLaunching(_ n: Notification) {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    menu = NSMenu()
    menu.autoenablesItems = false

    stateLine = makeInfoItem("Checking…")
    detailLine = makeInfoItem("")
    ipLine = makeInfoItem("Exit IP: …")
    menu.addItem(.separator())

    startItem = addAction("Start Alfa", #selector(startAlfa), "s")
    stopItem = addAction("Stop Alfa (VM off)", #selector(stopAlfa), "x")
    menu.addItem(.separator())

    joinItem = menu.addItem(withTitle: "Connect to Wi-Fi…", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    sub.delegate = self
    sub.autoenablesItems = false
    joinItem.submenu = sub
    disconnectItem = addAction("Disconnect Wi-Fi", #selector(disconnectWifi), "")
    menu.addItem(.separator())

    useAlfaItem = addAction("Use Alfa (Proxy ON)", #selector(forceOn), "a")
    useMacItem = addAction("Use MacBook Wi-Fi (Proxy OFF)", #selector(forceOff), "m")
    watchItem = addAction("Auto-switch (Watch)", #selector(toggleWatch), "w")
    menu.addItem(.separator())

    _ = addAction("Open TUI (alfa)", #selector(openTUI), "o")
    _ = addAction("Re-attach USB", #selector(reattachUSB), "u")
    _ = addAction("Open VM Shell", #selector(openShell), "t")
    _ = addAction("View Watch Log", #selector(viewLog), "l")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    item.menu = menu
    renderUI()
    pollStatus()
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.pollStatus() }
  }

  func makeInfoItem(_ title: String) -> NSMenuItem {
    let it = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
    it.isEnabled = false
    return it
  }

  func addAction(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
    let it = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
    it.target = self
    return it
  }

  func renderUI() {
    let s = status
    if let busy = busyText {
      item.button?.title = "⏳"
      stateLine.title = "⏳ \(busy)"
    } else if s.routingViaAlfa {
      item.button?.title = "📡"
      stateLine.title = "🟢 Routing via Alfa"
    } else if s.vm && !s.ssid.isEmpty {
      item.button?.title = "🟡"
      stateLine.title = "🟡 Alfa connected (MacBook Wi-Fi active)"
    } else if s.vm {
      item.button?.title = "🟡"
      stateLine.title = "🟡 VM running · MacBook Wi-Fi active"
    } else {
      item.button?.title = "◎"
      stateLine.title = "⚪︎ MacBook Wi-Fi"
    }

    var parts: [String] = []
    parts.append("Dongle: \(s.dongle ? "plugged" : "unplugged")")
    parts.append("VM: \(s.vm ? "on" : "off")")
    if !s.ssid.isEmpty {
      let rf = [s.signal.isEmpty ? nil : "\(s.signal) dBm", s.band.isEmpty ? nil : s.band].compactMap { $0 }.joined(separator: ", ")
      parts.append(rf.isEmpty ? s.ssid : "\(s.ssid) (\(rf))")
    } else if s.vm && !s.iface.isEmpty {
      parts.append("Wi-Fi: disconnected")
    }
    detailLine.title = parts.joined(separator: " · ")
    ipLine.title = "Exit IP: \(exitIP)"

    let busy = (busyText != nil)
    startItem.isEnabled = !busy
    stopItem.isEnabled = !busy && (s.vm || s.sysProxy || s.proxy)
    disconnectItem.isEnabled = !busy && s.vm && !s.ssid.isEmpty
    useAlfaItem.isEnabled = !busy && s.vm && !s.ssid.isEmpty
    useAlfaItem.state = s.routingViaAlfa ? .on : .off
    useMacItem.isEnabled = !busy
    useMacItem.state = !s.routingViaAlfa ? .on : .off
    watchItem.state = (s.watch && s.mode != "off") ? .on : .off
    watchItem.title = s.watch ? (s.mode == "off" ? "Auto-switch (Paused)" : "Auto-switch (Watch)") : "Auto-switch (Watch: Off)"
  }

  func pollStatus() {
    pollQ.async { [weak self] in
      guard let self = self, !self.isPolling else { return }
      self.isPolling = true
      defer { self.isPolling = false }
      let (_, out) = runAlfa(["status"])
      let parsed = parseStatus(out)
      DispatchQueue.main.async {
        let routeChanged = (self.lastRouteState != parsed.routingViaAlfa)
        self.lastRouteState = parsed.routingViaAlfa
        self.status = parsed
        self.renderUI()
        if routeChanged || Date().timeIntervalSince(self.lastIPFetch) > 15 {
          self.fetchExitIP(viaAlfa: parsed.routingViaAlfa)
        }
      }
    }
  }

  func fetchExitIP(viaAlfa: Bool) {
    ipQ.async { [weak self] in
      guard let self = self, !self.isFetchingIP else { return }
      self.isFetchingIP = true
      defer { self.isFetchingIP = false }
      let args = viaAlfa
        ? ["-s", "--max-time", "3", "--socks5-hostname", "127.0.0.1:1080", "https://ifconfig.me"]
        : ["-s", "--max-time", "3", "--noproxy", "*", "https://ifconfig.me"]
      let (code, out) = runExec("/usr/bin/curl", args)
      let ip = (code == 0 && !out.isEmpty && out.count < 64) ? out : "offline"
      DispatchQueue.main.async {
        self.lastIPFetch = Date()
        self.exitIP = ip
        self.renderUI()
      }
    }
  }

  func scanWifi(force: Bool) {
    scanQ.async { [weak self] in
      guard let self = self, !self.isScanning else { return }
      if !force && (!self.status.vm || self.status.iface.isEmpty) { return }
      self.isScanning = true
      defer { self.isScanning = false }
      let (_, out) = runAlfa(["scan"])
      var found: [Network] = []
      for line in out.split(separator: "\n") {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard !cols.isEmpty, !cols[0].isEmpty else { continue }
        let sig = cols.count > 1 ? cols[1] : ""
        let freq = cols.count > 2 ? cols[2] : ""
        found.append(Network(ssid: cols[0], signal: sig, freq: freq))
      }
      DispatchQueue.main.async {
        if !found.isEmpty || force { self.networks = Array(found.prefix(15)) }
      }
    }
  }

  func runOperation(_ label: String, work: @escaping () -> String?) {
    DispatchQueue.main.async {
      self.busyText = label
      self.renderUI()
    }
    opQ.async { [weak self] in
      let errMsg = work()
      let (_, out) = runAlfa(["status"])
      let parsed = parseStatus(out)
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.busyText = nil
        self.status = parsed
        self.renderUI()
        self.fetchExitIP(viaAlfa: parsed.routingViaAlfa)
        if let err = errMsg {
          self.showAlert(title: "AlfaBar", message: err)
        }
      }
    }
  }

  func showAlert(title: String, message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.runModal()
  }

  func promptPassword(ssid: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "Connect to \"\(ssid)\""
    a.informativeText = "Enter Wi-Fi password (leave blank for open network):"
    a.addButton(withTitle: "Connect")
    a.addButton(withTitle: "Cancel")
    let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    a.accessoryView = f
    a.window.initialFirstResponder = f
    return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
  }

  func menuNeedsUpdate(_ m: NSMenu) {
    m.removeAllItems()
    if !status.vm {
      let it = m.addItem(withTitle: "Start Alfa VM first", action: nil, keyEquivalent: "")
      it.isEnabled = false
      return
    }
    if !status.dongle || status.iface.isEmpty {
      let it = m.addItem(withTitle: status.dongle ? "Attaching USB… click Re-attach USB" : "Plug in Alfa USB dongle", action: nil, keyEquivalent: "")
      it.isEnabled = false
      return
    }
    if networks.isEmpty {
      let it = m.addItem(withTitle: isScanning ? "Scanning…" : "No networks cached yet", action: nil, keyEquivalent: "")
      it.isEnabled = false
      scanWifi(force: true)
    } else {
      for net in networks {
        let meta = [net.signal.isEmpty ? nil : "\(net.signal) dBm", net.band.isEmpty ? nil : net.band].compactMap { $0 }.joined(separator: " · ")
        let title = meta.isEmpty ? net.ssid : "\(net.ssid)  (\(meta))"
        let it = m.addItem(withTitle: title, action: #selector(joinFromMenu(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = net.ssid
        if net.ssid == status.ssid { it.state = .on }
      }
    }
    m.addItem(.separator())
    let other = m.addItem(withTitle: "Other network…", action: #selector(joinOther), keyEquivalent: "")
    other.target = self
    let rescan = m.addItem(withTitle: "Rescan now", action: #selector(rescanNow), keyEquivalent: "")
    rescan.target = self
  }

  @objc func startAlfa() {
    runOperation("Starting Alfa…") {
      let (code, out) = runAlfa(["start"])
      return code == 0 ? nil : (out.isEmpty ? "Failed to start Alfa VM" : out)
    }
  }

  @objc func stopAlfa() {
    runOperation("Stopping VM…") {
      _ = runAlfa(["stop"])
      return nil
    }
  }

  @objc func joinFromMenu(_ sender: NSMenuItem) {
    guard let ssid = sender.representedObject as? String else { return }
    if let saved = savedPassword(for: ssid) {
      connect(ssid: ssid, pass: saved, askOnFail: true)
    } else if let pass = promptPassword(ssid: ssid) {
      connect(ssid: ssid, pass: pass, askOnFail: false)
    }
  }

  @objc func joinOther() {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "Join Wi-Fi Network"
    a.addButton(withTitle: "Connect")
    a.addButton(withTitle: "Cancel")
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
    let ssidField = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
    ssidField.placeholderString = "Network Name (SSID)"
    let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    passField.placeholderString = "Password (blank if open)"
    box.addSubview(ssidField)
    box.addSubview(passField)
    a.accessoryView = box
    a.window.initialFirstResponder = ssidField
    guard a.runModal() == .alertFirstButtonReturn else { return }
    let ssid = ssidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ssid.isEmpty else { return }
    connect(ssid: ssid, pass: passField.stringValue, askOnFail: false)
  }

  func connect(ssid: String, pass: String, askOnFail: Bool) {
    runOperation("Joining \(ssid)…") { [weak self] in
      try? "auto".write(toFile: MODE_FILE, atomically: true, encoding: .utf8)
      let (code, out) = runAlfa(["wifi", ssid, pass])
      if code == 0 {
        _ = runAlfa(["proxy", "on"])
        return nil
      }
      if askOnFail {
        DispatchQueue.main.async {
          if let newPass = self?.promptPassword(ssid: ssid) {
            self?.connect(ssid: ssid, pass: newPass, askOnFail: false)
          }
        }
        return nil
      }
      return "Failed to join \"\(ssid)\".\n\n\(out)"
    }
  }

  @objc func disconnectWifi() {
    runOperation("Disconnecting Wi-Fi…") {
      try? "off".write(toFile: MODE_FILE, atomically: true, encoding: .utf8)
      _ = runAlfa(["proxy", "off"])
      _ = runAlfa(["wifi", "off"])
      return nil
    }
  }

  @objc func forceOn() {
    runOperation("Enabling Alfa proxy…") {
      try? "auto".write(toFile: MODE_FILE, atomically: true, encoding: .utf8)
      let (code, out) = runAlfa(["proxy", "on"])
      return code == 0 ? nil : (out.isEmpty ? "Failed to enable proxy" : out)
    }
  }

  @objc func forceOff() {
    runOperation("Switching to MacBook Wi-Fi…") {
      try? "off".write(toFile: MODE_FILE, atomically: true, encoding: .utf8)
      _ = runAlfa(["proxy", "off"])
      return nil
    }
  }

  @objc func toggleWatch() {
    let currentlyActive = status.watch && status.mode != "off"
    runOperation(currentlyActive ? "Disabling auto-switch…" : "Enabling auto-switch…") {
      let uid = String(getuid())
      if currentlyActive {
        try? "off".write(toFile: MODE_FILE, atomically: true, encoding: .utf8)
        _ = runExec("/bin/launchctl", ["bootout", "gui/\(uid)/com.alfa.watch"])
        _ = runExec("/usr/bin/pkill", ["-f", "alfa-vm/watch.sh"])
      } else {
        try? "auto".write(toFile: MODE_FILE, atomically: true, encoding: .utf8)
        _ = runExec("/bin/launchctl", ["bootout", "gui/\(uid)/com.alfa.watch"])
        let (code, _) = runExec("/bin/launchctl", ["bootstrap", "gui/\(uid)", WATCH_PLIST])
        if code != 0 {
          _ = runExec("/bin/launchctl", ["load", "-w", WATCH_PLIST])
        }
      }
      return nil
    }
  }

  @objc func reattachUSB() {
    runOperation("Attaching USB…") {
      let (code, out) = runAlfa(["usb-on"])
      return code == 0 ? nil : (out.isEmpty ? "Failed to attach USB dongle" : out)
    }
  }

  @objc func rescanNow() {
    scanWifi(force: true)
  }

  @objc func openTUI() {
    opQ.async {
      _ = runExec("/usr/bin/osascript", [
        "-e", "tell application \"Terminal\" to activate",
        "-e", "tell application \"Terminal\" to do script \"alfa\""
      ])
    }
  }

  @objc func openShell() {
    opQ.async {
      _ = runExec("/usr/bin/osascript", [
        "-e", "tell application \"Terminal\" to activate",
        "-e", "tell application \"Terminal\" to do script \"cd '\(VM)' && ./alfa.sh ssh\""
      ])
    }
  }

  @objc func viewLog() {
    opQ.async {
      _ = runExec("/usr/bin/osascript", [
        "-e", "tell application \"Terminal\" to activate",
        "-e", "tell application \"Terminal\" to do script \"touch '\(LOG_FILE)' && tail -n 50 -f '\(LOG_FILE)'\""
      ])
    }
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
