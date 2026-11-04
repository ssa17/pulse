import Cocoa
import WebKit
import Sparkle

// Pulse — native shell for the local resource dashboard.
// - single instance: a second launch focuses the first and exits
// - reuses a running backend via ~/.pulse/port, else spawns one on a dynamic port
// - shows the dashboard in a WKWebView
// - live menu-bar status item with CPU + memory graphs
// - native confirm/alert/prompt dialogs (WKUIDelegate)

let host = "127.0.0.1"
let pulseDir = NSHomeDirectory() + "/.pulse"
let settingsFile = pulseDir + "/settings.json"

func readSettings() -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsFile)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}

func writeSettings(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
    try? FileManager.default.createDirectory(atPath: pulseDir, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: settingsFile))
}

func urlForPort(_ port: Int, _ path: String) -> URL {
    URL(string: "http://\(host):\(port)\(path)")!
}

func readPortFile() -> Int? {
    guard let s = try? String(contentsOfFile: pulseDir + "/port", encoding: .utf8) else { return nil }
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Locate a node binary: $PULSE_NODE → common install paths → nvm → login shell.
func findNode() -> String? {
    let fm = FileManager.default
    let env = ProcessInfo.processInfo.environment
    if let p = env["PULSE_NODE"], fm.isExecutableFile(atPath: p) { return p }
    for c in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] where fm.isExecutableFile(atPath: c) {
        return c
    }
    let nvmDir = NSHomeDirectory() + "/.nvm/versions/node"
    if let vers = try? fm.contentsOfDirectory(atPath: nvmDir), let newest = vers.sorted(by: >).first {
        let p = nvmDir + "/" + newest + "/bin/node"
        if fm.isExecutableFile(atPath: p) { return p }
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-lc", "command -v node"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty, fm.isExecutableFile(atPath: out) { return out }
    } catch {}
    return nil
}

/// Is a *valid* Pulse server listening on this port?
func serverIsAlive(port: Int) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var up = false
    var req = URLRequest(url: urlForPort(port, "/api/snapshot"))
    req.timeoutInterval = 1.5
    let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
        // require a real Pulse payload, so a stale/foreign server on the port is not reused
        if let h = resp as? HTTPURLResponse, h.statusCode == 200,
           let s = String(data: data ?? Data(), encoding: .utf8),
           s.contains("\"apps\""), s.contains("\"sys\"") { up = true }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 2.0)
    return up
}

/* ================================================================== *
 *  Menu-bar status item: live CPU + memory graphs, like oMLX's.
 * ================================================================== */
final class StatusController {
    let item = NSStatusBar.system.statusItem(withLength: 76)
    var cpuHist: [Double] = []
    var memHist: [Double] = []
    var timer: Timer?
    var samples = 0
    var port: Int?

    let cpuItem = NSMenuItem(title: "CPU —", action: nil, keyEquivalent: "")
    let memItem = NSMenuItem(title: "Memory —", action: nil, keyEquivalent: "")
    let topCpuItem = NSMenuItem(title: "Top CPU —", action: nil, keyEquivalent: "")
    let topMemItem = NSMenuItem(title: "Top Memory —", action: nil, keyEquivalent: "")
    let barModeItem = NSMenuItem(title: "▥ Vertical Bars", action: #selector(toggleBarMode(_:)), keyEquivalent: "")

    init() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let title = NSMenuItem(title: "Pulse v\(ver)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(cpuItem)
        menu.addItem(memItem)
        menu.addItem(topCpuItem)
        menu.addItem(topMemItem)
        menu.addItem(.separator())
        menu.addItem(barModeItem)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Pulse", action: #selector(Shell.openApp), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(open)
        menu.addItem(quit)
        item.menu = menu
        item.button?.image = Self.render(cpu: [], mem: [])
    }

    func start(port: Int) {
        guard self.port == nil else { return }
        self.port = port
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    @objc func toggleBarMode(_ sender: NSMenuItem) {
        let current = (readSettings()["statusBarGraphType"] as? String) ?? "sparkline"
        let next = current == "bars" ? "sparkline" : "bars"
        var s = readSettings()
        s["statusBarGraphType"] = next
        writeSettings(s)
        sender.title = next == "bars" ? "▥ Vertical Bars" : "◈ Sparklines"
        item.button?.image = Self.render(cpu: cpuHist, mem: memHist)  // bars with no samples → empty tracks
    }

    func poll() {
        guard let port else { return }
        var req = URLRequest(url: urlForPort(port, "/api/status"))
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self,
                  let h = resp as? HTTPURLResponse, h.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
            else { return }
            DispatchQueue.main.async {
                self.samples += 1
                if let c = obj["cpu"] as? [String: Any], let t = c["total"] as? Double {
                    self.cpuHist.append(t)
                }
                if let m = obj["memPct"] as? Double { self.memHist.append(m) }
                if self.cpuHist.count > 40 { self.cpuHist.removeFirst(self.cpuHist.count - 40) }
                if self.memHist.count > 40 { self.memHist.removeFirst(self.memHist.count - 40) }
                self.item.button?.image = Self.render(cpu: self.cpuHist, mem: self.memHist)
                self.updateMenu(obj)
            }
        }.resume()
    }

    func updateMenu(_ o: [String: Any]) {
        let gb: (Double) -> String = { String(format: "%.1f GB", $0 / 1_073_741_824) }
        if let c = o["cpu"] as? [String: Any], let t = c["total"] as? Double {
            cpuItem.title = String(format: "CPU  %.1f%%   (user %.1f / sys %.1f)",
                                   t, c["user"] as? Double ?? 0, c["sys"] as? Double ?? 0)
        }
        if let p = o["memPct"] as? Double, let u = o["memUsed"] as? Double, let tt = o["memTotal"] as? Double {
            memItem.title = String(format: "Memory  %.0f%%   (%@ of %@)", p, gb(u), gb(tt))
        }
        if let t = o["topCpu"] as? [String: Any], let n = t["name"] as? String {
            topCpuItem.title = "Top CPU  \(n)  (\(String(format: "%.1f%%", t["cpu"] as? Double ?? 0)))"
        }
        if let t = o["topMem"] as? [String: Any], let n = t["name"] as? String, let m = t["mem"] as? Double {
            topMemItem.title = "Top Memory  \(n)  (\(gb(m)))"
        }
    }

    /// Status bar rendering — sparkline or vertical bar mode.
    static func render(cpu: [Double], mem: [Double]) -> NSImage {
        let style = (readSettings()["statusBarGraphType"] as? String) ?? "sparkline"
        if style == "bars" { return renderBars(cpu: cpu.last, mem: mem.last) }
        return renderSparklines(cpu: cpu, mem: mem)
    }

    /// Two stacked sparklines: CPU (orange) over Memory (blue).
    static func renderSparklines(cpu: [Double], mem: [Double]) -> NSImage {
        let w: CGFloat = 72, h: CGFloat = 22
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
        func line(_ data: [Double], _ maxV: Double, _ y0: CGFloat, _ hgt: CGFloat, _ color: NSColor) {
            guard data.count > 1 else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            let step = (w - 8) / 39
            for (i, v) in data.enumerated() {
                let x = 4 + CGFloat(i) * step
                let y = y0 + hgt - CGFloat(min(max(v, 0) / maxV, 1)) * hgt
                i == 0 ? ctx.move(to: CGPoint(x: x, y: y)) : ctx.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.strokePath()
        }
        line(cpu, 100, 11, 9, NSColor(red: 1.0, green: 0.62, blue: 0.26, alpha: 1))
        line(mem, 100, 1, 9, NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1))
        img.unlockFocus()
        return img
    }

    /// Vertical capsule bars (oMLX-style): a stacked letter column beside a thin
    /// rounded bar, filled from the bottom in the metric's colour.
    static func renderBars(cpu: Double?, mem: Double?) -> NSImage {
        let w: CGFloat = 54, h: CGFloat = 22
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
        let barW: CGFloat = 9, barH: CGFloat = 18
        let barY: CGFloat = (h - barH) / 2
        let letterAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        func metric(_ x: CGFloat, _ label: String, _ value: Double?, _ color: NSColor) {
            // stacked letters, top-aligned with the bar, one per line
            let lineH = barH / CGFloat(label.count)
            for (j, ch) in label.enumerated() {
                (String(ch) as NSString).draw(
                    in: NSRect(x: x, y: barY + barH - lineH * CGFloat(j + 1), width: 7, height: lineH),
                    withAttributes: letterAttrs)
            }
            // slightly-rounded track
            let bx = x + 8
            let cr: CGFloat = 2   // subtle corner rounding (was a full capsule, then 0)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1)
            NSBezierPath(roundedRect: NSRect(x: bx, y: barY, width: barW, height: barH),
                         xRadius: cr, yRadius: cr).stroke()
            // fill from the bottom (slightly-rounded)
            if let v = value, v > 0 {
                let fh = CGFloat(min(v, 100) / 100) * barH
                if fh > 0 {
                    // keep the fill's corners in proportion so a short fill looks the same
                    let fr = min(cr, fh / 2, barW / 2)
                    let fill = NSBezierPath(roundedRect: NSRect(x: bx, y: barY, width: barW, height: fh),
                                             xRadius: fr, yRadius: fr)
                    ctx.setFillColor(color.cgColor)
                    fill.fill()
                }
            }
        }
        metric(4, "CPU", cpu, NSColor(red: 1.0, green: 0.62, blue: 0.26, alpha: 1))
        metric(32, "MEM", mem, NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1))
        img.unlockFocus()
        return img
    }
}

/* ================================================================== *
 *  App shell
 * ================================================================== */
final class Shell: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var nodeProc: Process?
    var spawnedNode = false
    var quitting = false
    var loaded = false
    var serverPort: Int?
    var status: StatusController?
    var updater: SPUStandardUpdaterController!

    @objc func reload() { web.reload() }
    @objc func openApp() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Single instance: if another Pulse is already running, focus it and exit.
        // (Skipped for self-tests, which run the binary directly.)
        if ProcessInfo.processInfo.environment["PULSE_SELFTEST"] != "1",
           let bid = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }

        let rect = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Pulse"
        window.minSize = NSSize(width: 940, height: 620)
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.07, alpha: 1)

        web = WKWebView(frame: rect)
        web.navigationDelegate = self
        web.uiDelegate = self
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.07, alpha: 1)
        }
        window.contentView = web

        // Minimal menu: Cmd-Q, Cmd-R, and copy/paste for the search field.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pulse",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let checkUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        appMenu.addItem(checkUpdates)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Pulse",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        viewItem.submenu = viewMenu
        NSApp.mainMenu = mainMenu

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Sparkle auto-updates: start the updater (checks SUFeedURL on launch + periodically).
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        status = StatusController()
        for mi in [status?.cpuItem, status?.memItem, status?.topCpuItem, status?.topMemItem] {
            mi?.isEnabled = false
        }
        if let menu = status?.item.menu {
            for mi in menu.items where mi.title == "Open Pulse" { mi.target = self }
            // Wire up bar mode toggle
            if let mi = status?.barModeItem {
                let cur = (readSettings()["statusBarGraphType"] as? String) ?? "sparkline"
                mi.title = cur == "bars" ? "▥ Vertical Bars" : "◈ Sparklines"
                mi.target = status
                mi.action = #selector(StatusController.toggleBarMode(_:))
            }
        }

        startServer()
    }

    /// Reuse a running backend (port file / $PULSE_PORT) or spawn one on a dynamic port.
    func startServer() {
        if let forced = ProcessInfo.processInfo.environment["PULSE_PORT"].flatMap({ Int($0) }) {
            if serverIsAlive(port: forced) {
                serverPort = forced
                beginService()
            } else {
                spawnBackend(portOverride: forced)
            }
            return
        }
        if let p = readPortFile(), serverIsAlive(port: p) {
            serverPort = p
            beginService()
            return
        }
        spawnBackend(portOverride: nil)
    }

    func spawnBackend(portOverride: Int?) {
        guard let node = findNode() else {
            showFatal("Node.js was not found.\nInstall it (brew install node) or set PULSE_NODE=/path/to/node, then reopen Pulse.")
            return
        }
        let res = Bundle.main.resourcePath ?? "."
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [res + "/server.js"]
        var env = ProcessInfo.processInfo.environment
        env["PULSE"] = "1"
        env["PORT"] = portOverride.map(String.init) ?? "0" // 0 → OS assigns a free port
        env["NODE_OPTIONS"] = "--max-old-space-size=192"   // keep the backend lean
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            env["PULSE_VERSION"] = v   // the dashboard shows it in the header
        }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.quitting else { return }
                if proc.terminationReason == .uncaughtSignal || proc.terminationStatus != 0 {
                    self.showFatal("The Pulse backend exited unexpectedly (status \(proc.terminationStatus)).\nReopen the app to try again.")
                }
            }
        }
        do {
            try p.run()
            nodeProc = p
            spawnedNode = true
        } catch {
            showFatal("Could not start the Pulse backend:\n\(error.localizedDescription)")
            return
        }
        // The backend announces its port on stdout as soon as it is listening.
        DispatchQueue.global().async { [weak self] in
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break } // EOF — backend exited
                guard let s = String(data: data, encoding: .utf8) else { continue }
                for line in s.components(separatedBy: "\n") where line.hasPrefix("PULSE_LISTENING=") {
                    if let port = Int(line.dropFirst("PULSE_LISTENING=".count)) {
                        DispatchQueue.main.async {
                            self?.serverPort = port
                            self?.beginService()
                        }
                    }
                }
            }
        }
    }

    func beginService() {
        guard let port = serverPort, !loaded else { return }
        loaded = true
        // Cache-busting query: WKWebView's persistent cache keys on the full
        // URL, so a fresh load must not be answerable from a previous launch.
        // (The server splits on '?' — routing is unaffected.)
        let path = "/?r=\(Int(Date().timeIntervalSince1970 * 1000))"
        web.load(URLRequest(url: urlForPort(port, path)))
        status?.start(port: port)
        // PULSE_SELFTEST=1 → verify render + interactions, then exit.
        // (__autoconfirm is injected in didFinish, once the real page context exists.)
        // NOTE: the JS below depends on DOM ids in public/index.html
        // (#rows-cpu .row, #dtable .prow, #dclose, #machine, #cpu-big,
        // #mem-big, #live-text, #ver, #mem-info, #mempop/#pop-*) — keep the two
        // files in sync (see docs/contracts.md).
        if ProcessInfo.processInfo.environment["PULSE_SELFTEST"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                guard let self else { return }
                // NOTE: must stay synchronous — this WebKit does not await promises in evaluateJavaScript.
                let js = """
                (() => {
                  let confirmWired = null;
                  if (window.__autoconfirm) confirmWired = confirm('selftest');
                  // first VISIBLE row — hidden cached rows (exited apps) would open an
                  // empty drawer and read 0
                  const row = [...document.querySelectorAll('#rows-cpu .row')].find(r => r.style.display !== 'none');
                  if (row) row.click();
                  const drawerRows = document.querySelectorAll('#dtable .prow').length;
                  document.querySelector('#dclose')?.click();
                  // Memory info popover: open it, read back the rendered values,
                  // close it.
                  document.querySelector('#mem-info')?.click();
                  const memInfo = {
                    open: !document.querySelector('#mempop')?.hidden,
                    wired: document.querySelector('#pop-wired')?.textContent || null,
                    comp: document.querySelector('#pop-comp')?.textContent || null,
                    cache: document.querySelector('#pop-cache')?.textContent || null
                  };
                  document.querySelector('#mem-info')?.click();
                  return JSON.stringify({
                    machine: document.querySelector('#machine')?.textContent,
                    ver: document.querySelector('#ver')?.textContent,
                    cpu: document.querySelector('#cpu-big')?.textContent,
                    mem: document.querySelector('#mem-big')?.textContent,
                    rows: document.querySelectorAll('#rows-cpu .row').length,
                    live: document.querySelector('#live-text')?.textContent,
                    confirmWired, drawerRows, memInfo
                  });
                })()
                """
                self.web.evaluateJavaScript(js) { d, _ in
                    let statusOk = self.status?.samples ?? 0
                    print("SELFTEST: " + (d as? String ?? "eval-failed") +
                          " port=" + String(self.serverPort ?? -1) +
                          " statusItemSamples=" + String(statusOk) +
                          " statusItemImage=" + ((self.status?.item.button?.image != nil) ? "ok" : "missing"))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func showFatal(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Pulse"
        a.informativeText = msg
        a.alertStyle = .warning
        a.runModal()
        NSApp.terminate(nil)
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Inject test flags only after the real page context exists
        // (setting them before load would be wiped when the page replaces about:blank).
        if ProcessInfo.processInfo.environment["PULSE_AUTOCONFIRM"] == "1" {
            web.evaluateJavaScript("window.__autoconfirm = true") { _, _ in }
        }
    }

    // MARK: WKUIDelegate — native dialogs for confirm()/alert()/prompt()
    // (without this, confirm() in a WKWebView silently returns false and
    //  the kill / quit-app buttons appear to do nothing)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "Pulse"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        if ProcessInfo.processInfo.environment["PULSE_AUTOCONFIRM"] == "1" {
            DispatchQueue.main.async { completionHandler(true) } // test mode: auto-approve
            return
        }
        let a = NSAlert()
        a.messageText = "Pulse"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = prompt
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        // Make sure the backend we spawned actually dies (otherwise it would be orphaned).
        if spawnedNode, let p = nodeProc, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            while p.isRunning { usleep(50_000) }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension NSWindow {
    @objc fileprivate func swizzled_needsTilingConstraintUpdate() -> Bool {
        if String(describing: type(of: self)).contains("NSStatusBarWindow") {
            return false
        }
        return self.swizzled_needsTilingConstraintUpdate()
    }

    static func disableStatusBarTilingConstraintSpam() {
        let originalSelector = NSSelectorFromString("_needsTilingConstraintUpdate")
        let swizzledSelector = #selector(NSWindow.swizzled_needsTilingConstraintUpdate)
        guard let originalMethod = class_getInstanceMethod(NSWindow.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSWindow.self, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

let app = NSApplication.shared
NSWindow.disableStatusBarTilingConstraintSpam()
let shell = Shell()
app.delegate = shell
app.setActivationPolicy(.regular)
app.run()
