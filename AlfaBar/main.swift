// AlfaBar — ultra-simple emoji menu bar ON/OFF controller for Alfa AWUS1900 (AppKit).
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
let LOG_FILE = "/tmp/alfa-autoswitch.log"
let WATCH_PLIST = NSHomeDirectory() + "/Library/LaunchAgents/com.alfa.autoswitch.plist"
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
  var bonded = false
  var mode = "on"

  var isEnabled: Bool { mode != "off" }
  var hasWifi: Bool { vm && !ssid.isEmpty && !ip.isEmpty }
  var routingViaAlfa: Bool { hasWifi && sysProxy && proxy }
  var feedingBond: Bool { hasWifi && bonded && isEnabled }
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
  var dot: String {
    let v = Int(signal) ?? -90
    if v >= -65 { return "🟢" }
    if v >= -76 { return "🟡" }
    return "🟠"
  }
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
    case "bonded": s.bonded = (v == "1")
    case "mode": s.mode = v.isEmpty ? "on" : v
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

func ensureAutoswitchRunning() {
  if runExec("/usr/bin/pgrep", ["-f", "alfa-autoswitch\\.sh"]).0 == 0 { return }
  guard FileManager.default.fileExists(atPath: WATCH_PLIST) else { return }
  let uid = String(getuid())
  let (code, _) = runExec("/bin/launchctl", ["bootstrap", "gui/\(uid)", WATCH_PLIST])
  if code != 0 {
    _ = runExec("/bin/launchctl", ["load", "-w", WATCH_PLIST])
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var item: NSStatusItem!
  var menu: NSMenu!
  var stateLine: NSMenuItem!
  var detailLine: NSMenuItem!
  var toggleItem: NSMenuItem!
  var joinItem: NSMenuItem!

  let pollQ = DispatchQueue(label: "com.alfabar.poll")
  let opQ = DispatchQueue(label: "com.alfabar.op")
  let scanQ = DispatchQueue(label: "com.alfabar.scan")

  var status = Status()
  var networks: [Network] = []
  var busyText: String? = nil
  var isPolling = false
  var isScanning = false

  func applicationDidFinishLaunching(_ n: Notification) {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    menu = NSMenu()
    menu.autoenablesItems = false

    stateLine = makeInfoItem("⏳ Checking…", bold: true)
    detailLine = makeInfoItem("", bold: false)
    menu.addItem(.separator())

    toggleItem = addAction("🟢 Turn Alfa ON", #selector(toggleAlfa), "s")

    joinItem = menu.addItem(withTitle: "📶 Wi-Fi Network…", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    sub.delegate = self
    sub.autoenablesItems = false
    joinItem.submenu = sub

    menu.addItem(.separator())

    let toolsRoot = menu.addItem(withTitle: "🔧 Tools", action: nil, keyEquivalent: "")
    let tools = NSMenu()
    let usb = tools.addItem(withTitle: "🔌 Re-attach USB", action: #selector(reattachUSB), keyEquivalent: "")
    usb.target = self
    let tui = tools.addItem(withTitle: "💻 Terminal (alfa)", action: #selector(openTUI), keyEquivalent: "")
    tui.target = self
    let log = tools.addItem(withTitle: "📄 View Log", action: #selector(viewLog), keyEquivalent: "")
    log.target = self
    toolsRoot.submenu = tools

    let quit = menu.addItem(withTitle: "🚪 Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.target = NSApp

    item.menu = menu
    renderUI()
    pollStatus()
    Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.pollStatus() }
  }

  func makeInfoItem(_ title: String, bold: Bool) -> NSMenuItem {
    let it = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
    it.isEnabled = false
    setStyled(it, title, bold: bold, dim: !bold)
    return it
  }

  func setStyled(_ it: NSMenuItem, _ text: String, bold: Bool, dim: Bool) {
    var attrs: [NSAttributedString.Key: Any] = [
      .font: bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 12)
    ]
    if dim { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
    it.attributedTitle = NSAttributedString(string: text, attributes: attrs)
  }

  func addAction(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
    let it = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
    it.target = self
    return it
  }

  func renderUI() {
    let s = status
    let isOn = s.isEnabled || s.vm

    if let busy = busyText {
      item.button?.title = "⏳ 📡"
      setStyled(stateLine, "⏳ \(busy)", bold: true, dim: false)
    } else if s.routingViaAlfa {
      item.button?.title = "🟢 📡"
      setStyled(stateLine, "🟢 Alfa ON · Default Internet", bold: true, dim: false)
    } else if s.feedingBond {
      item.button?.title = "🟢 📡"
      setStyled(stateLine, "🟢 Alfa ON · Combined in Open Speedify", bold: true, dim: false)
    } else if isOn && !s.dongle {
      item.button?.title = "🟡 📡"
      setStyled(stateLine, "🟡 Alfa ON · Plug in USB dongle", bold: true, dim: false)
    } else if isOn {
      item.button?.title = "🟡 📡"
      setStyled(stateLine, "🟡 Alfa ON · Connecting…", bold: true, dim: false)
    } else {
      item.button?.title = "⚪ 📡"
      setStyled(stateLine, "⚪ Alfa OFF", bold: true, dim: false)
    }

    var detail = ""
    if s.vm && !s.ssid.isEmpty {
      let rf = [s.signal.isEmpty ? nil : "\(s.signal) dBm", s.band.isEmpty ? nil : s.band].compactMap { $0 }.joined(separator: " · ")
      detail = rf.isEmpty ? "   📶 \(s.ssid)" : "   📶 \(s.ssid) · \(rf)"
    } else {
      detail = s.dongle ? "   🔌 USB dongle plugged in" : "   🔌 USB dongle unplugged"
    }
    setStyled(detailLine, detail, bold: false, dim: true)

    let busy = (busyText != nil)
    toggleItem.isEnabled = !busy
    toggleItem.title = isOn ? "🔴 Turn Alfa OFF" : "🟢 Turn Alfa ON"
    joinItem.isEnabled = !busy && s.vm && s.dongle && !s.iface.isEmpty
  }

  func pollStatus() {
    pollQ.async { [weak self] in
      guard let self = self, !self.isPolling else { return }
      self.isPolling = true
      defer { self.isPolling = false }
      let (_, out) = runAlfa(["status"])
      let parsed = parseStatus(out)
      DispatchQueue.main.async {
        self.status = parsed
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
        if let err = errMsg {
          self.showAlert(title: "📡 Alfa", message: err)
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
    a.messageText = "📶 Connect to \"\(ssid)\""
    a.informativeText = "Enter Wi-Fi password (blank if open):"
    a.addButton(withTitle: "Connect")
    a.addButton(withTitle: "Cancel")
    let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    a.accessoryView = f
    a.window.initialFirstResponder = f
    return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
  }

  func menuNeedsUpdate(_ m: NSMenu) {
    m.removeAllItems()
    if !status.vm || !status.dongle || status.iface.isEmpty {
      let it = m.addItem(withTitle: "Turn Alfa ON with dongle plugged in", action: nil, keyEquivalent: "")
      it.isEnabled = false
      return
    }
    if networks.isEmpty {
      let it = m.addItem(withTitle: isScanning ? "⏳ Scanning…" : "🔄 Click Rescan…", action: nil, keyEquivalent: "")
      it.isEnabled = false
      scanWifi(force: true)
    } else {
      for net in networks {
        let meta = [net.signal.isEmpty ? nil : "\(net.signal) dBm", net.band.isEmpty ? nil : net.band].compactMap { $0 }.joined(separator: " · ")
        let title = meta.isEmpty ? "\(net.dot) \(net.ssid)" : "\(net.dot) \(net.ssid)  (\(meta))"
        let it = m.addItem(withTitle: title, action: #selector(joinFromMenu(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = net.ssid
        if net.ssid == status.ssid { it.state = .on }
      }
    }
    m.addItem(.separator())
    let other = m.addItem(withTitle: "➕ Other network…", action: #selector(joinOther), keyEquivalent: "")
    other.target = self
    let rescan = m.addItem(withTitle: "🔄 Rescan", action: #selector(rescanNow), keyEquivalent: "")
    rescan.target = self
  }

  @objc func toggleAlfa() {
    let turningOff = status.isEnabled || status.vm
    if turningOff {
      runOperation("Turning Alfa OFF…") {
        _ = runAlfa(["stop"])
        return nil
      }
    } else {
      runOperation("Starting Alfa…") {
        ensureAutoswitchRunning()
        let (code, out) = runAlfa(["start"])
        return code == 0 ? nil : (out.isEmpty ? "Failed to start Alfa" : out)
      }
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
    a.messageText = "📶 Join Wi-Fi Network"
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
      try? "on\n".write(toFile: MODE_FILE, atomically: true, encoding: .utf8)
      ensureAutoswitchRunning()
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

  @objc func reattachUSB() {
    runOperation("Re-attaching USB…") {
      let (code, out) = runAlfa(["usb-on"])
      return code == 0 ? nil : (out.isEmpty ? "Failed to attach USB dongle" : out)
    }
  }

  @objc func rescanNow() { scanWifi(force: true) }

  @objc func openTUI() {
    opQ.async {
      _ = runExec("/usr/bin/osascript", [
        "-e", "tell application \"Terminal\" to activate",
        "-e", "tell application \"Terminal\" to do script \"alfa\""
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
