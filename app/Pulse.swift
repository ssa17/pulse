import Cocoa
import WebKit
import Sparkle

// Pulse — native shell for the local resource dashboard.
// - single instance: a second launch focuses/reopens the first and exits
// - reuses a running backend (LaunchAgent or prior session) via ~/.pulse/port,
//   else spawns one on a dynamic port
// - window close keeps Pulse running in the menu bar by default (configurable in Settings),
//   releasing the WKWebView by default so WebKit XPC processes exit while closed
// - live menu-bar status item with CPU + memory bars and quick settings toggles
// - native Settings window + LaunchAgent "Start at login" daemon management
// - native confirm/alert/prompt dialogs (WKUIDelegate)

let host = "127.0.0.1"
let pulseDir = NSHomeDirectory() + "/.pulse"
let isSelfTest = ProcessInfo.processInfo.environment["PULSE_SELFTEST"] == "1"
let reopenNotificationName = Notification.Name("local.pulse.monitor.reopen")
let closeWindowNotificationName = Notification.Name("local.pulse.monitor.closeWindow")

func urlForPort(_ port: Int, _ path: String) -> URL {
    URL(string: "http://\(host):\(port)\(path)")!
}

func readPortFile() -> Int? {
    guard let s = try? String(contentsOfFile: pulseDir + "/port", encoding: .utf8) else { return nil }
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func epochMsNow() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
}

/* ================================================================== *
 *  Privacy-safe startup & reopen trace (~/.pulse/boot-trace.log)
 *  Stage names + timestamps ONLY — never process names, args, or paths.
 * ================================================================== */
final class BootTracer {
    static let shared = BootTracer()
    private let queue = DispatchQueue(label: "local.pulse.boot-trace")
    private var sessionStartMs: Int64 = epochMsNow()
    private var currentMode: String = "launch"
    private var seenStages = Set<String>()
    private let maxSessions = 10

    var logPath: String {
        pulseDir + (isSelfTest ? "/boot-trace-selftest.log" : "/boot-trace.log")
    }

    func beginSession(mode: String, extra: String? = nil) {
        let nowMs = epochMsNow()
        let iso = ISO8601DateFormatter().string(from: Date())
        queue.sync {
            currentMode = mode
            sessionStartMs = nowMs
            seenStages.removeAll()
            try? FileManager.default.createDirectory(atPath: pulseDir, withIntermediateDirectories: true)
            let extraPart = extra.map { " \($0)" } ?? ""
            let header = "=== session mode=\(mode)\(extraPart) started=\(iso) ===\n"
            var existing = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            if !existing.isEmpty {
                let marker = "=== session "
                let parts = existing.components(separatedBy: marker).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let kept = parts.suffix(maxSessions - 1).map { marker + $0 }
                existing = kept.joined()
                if !existing.hasSuffix("\n") { existing += "\n" }
            }
            let updated = existing + header
            try? updated.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    func mark(_ stage: String, tsOverrideMs: Int64? = nil, once: Bool = false, launchOnly: Bool = false) {
        let nowMs = tsOverrideMs ?? epochMsNow()
        queue.async {
            if launchOnly && self.currentMode != "launch" { return }
            if once {
                if self.seenStages.contains(stage) { return }
                self.seenStages.insert(stage)
            }
            let elapsed = max(0, nowMs - self.sessionStartMs)
            let line = "stage=\(stage) ts=\(nowMs) elapsed_ms=\(elapsed)\n"
            if let fh = FileHandle(forWritingAtPath: self.logPath) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try? fh.write(contentsOf: data)
                }
            } else {
                try? FileManager.default.createDirectory(atPath: pulseDir, withIntermediateDirectories: true)
                try? line.write(toFile: self.logPath, atomically: true, encoding: .utf8)
            }
        }
    }

    func markBackendTrace(_ dict: [String: Any]?) {
        guard let dict else { return }
        if let firstSnap = (dict["firstSnapshot"] as? NSNumber)?.int64Value, firstSnap >= sessionStartMs {
            mark("backend_first_snapshot", tsOverrideMs: firstSnap, once: true, launchOnly: true)
        }
    }
}

/* ================================================================== *
 *  Versioned settings store (~/.pulse/settings.json)
 *  Migrates legacy `statusBarGraphType` while preserving unknown keys.
 * ================================================================== */
final class PulseSettings {
    static let currentVersion = 1
    let filePath: String
    var startAtLogin: Bool = false
    var closeBehavior: String = "background" // "background" | "quit"
    var keepDashboardInMemory: Bool = false
    private var storage: [String: Any] = [:]

    init(path: String = pulseDir + "/settings.json") {
        self.filePath = path
        reload(persistMigration: !isSelfTest)
    }

    func reload(persistMigration: Bool = true) {
        var needsSave = false
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            storage = obj
            let ver = obj["version"] as? Int ?? 0
            if ver < Self.currentVersion { needsSave = true }
            if storage.removeValue(forKey: "statusBarGraphType") != nil { needsSave = true }
            startAtLogin = (obj["startAtLogin"] as? Bool) ?? false
            if let cb = obj["closeBehavior"] as? String, (cb == "background" || cb == "quit") {
                closeBehavior = cb
            } else {
                closeBehavior = "background"
            }
            keepDashboardInMemory = (obj["keepDashboardInMemory"] as? Bool) ?? false
        } else {
            storage = [:]
            startAtLogin = false
            closeBehavior = "background"
            keepDashboardInMemory = false
        }
        if needsSave && persistMigration {
            save()
        }
    }

    func save() {
        storage.removeValue(forKey: "statusBarGraphType")
        storage["version"] = Self.currentVersion
        storage["startAtLogin"] = startAtLogin
        storage["closeBehavior"] = closeBehavior
        storage["keepDashboardInMemory"] = keepDashboardInMemory
        try? FileManager.default.createDirectory(atPath: (filePath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: storage, options: [.prettyPrinted, .sortedKeys]) {
            var out = data
            out.append(0x0A)
            try? out.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        }
    }

    var shouldQuitOnClose: Bool { closeBehavior == "quit" }
}

/* ================================================================== *
 *  Node & backend path resolution
 * ================================================================== */
/// Fast synchronous lookup across standard install locations (zero child processes).
func findNodeFast() -> String? {
    let fm = FileManager.default
    let env = ProcessInfo.processInfo.environment
    if let p = env["PULSE_NODE"], fm.isExecutableFile(atPath: p) { return p }
    let home = NSHomeDirectory()
    let directCandidates = [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
        "/opt/local/bin/node",
        home + "/.volta/bin/node",
        home + "/.asdf/shims/node",
        home + "/.local/share/mise/shims/node",
    ]
    for c in directCandidates where fm.isExecutableFile(atPath: c) {
        return c
    }
    let nvmDir = home + "/.nvm/versions/node"
    if let vers = try? fm.contentsOfDirectory(atPath: nvmDir), let newest = vers.sorted(by: >).first {
        let p = nvmDir + "/" + newest + "/bin/node"
        if fm.isExecutableFile(atPath: p) { return p }
    }
    let fnmDir = home + "/.fnm/node-versions"
    if let vers = try? fm.contentsOfDirectory(atPath: fnmDir), let newest = vers.sorted(by: >).first {
        let p = fnmDir + "/" + newest + "/installation/bin/node"
        if fm.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

/// Locate a node binary asynchronously so a slow login-shell rc file never blocks the main thread.
func findNodeAsync(completion: @escaping (String?) -> Void) {
    if let fast = findNodeFast() {
        completion(fast)
        return
    }
    DispatchQueue.global(qos: .userInitiated).async {
        let fm = FileManager.default
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        var found: String?
        do {
            try task.run()
            let deadline = Date().addingTimeInterval(2.5)
            while task.isRunning && Date() < deadline { usleep(25_000) }
            if task.isRunning { task.terminate() }
            task.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .components(separatedBy: "\n").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, fm.isExecutableFile(atPath: out) { found = out }
        } catch {}
        DispatchQueue.main.async { completion(found) }
    }
}

/// Resolve the backend script: inside a repo checkout (dist/Pulse.app/...),
/// prefer the checkout's server.js — matching server.js's own PUBLIC_DIR
/// lookup so UI and backend can never split-brain across edits. Installed
/// builds (/Applications/Pulse.app) use Contents/Resources/server.js.
func serverScriptPath() -> String {
    let fm = FileManager.default
    let res = Bundle.main.resourcePath ?? "."
    var url = URL(fileURLWithPath: res)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
        let candidate = url.appendingPathComponent("server.js").path
        let pub = url.appendingPathComponent("public/index.html").path
        if fm.isReadableFile(atPath: candidate), fm.isReadableFile(atPath: pub) {
            return candidate
        }
    }
    return res + "/server.js"
}

func expectedServerMtime() -> Int? {
    let p = serverScriptPath()
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
          let d = attrs[.modificationDate] as? Date else { return nil }
    return Int(d.timeIntervalSince1970)
}

let probeSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 1.0
    cfg.timeoutIntervalForResource = 1.0
    return URLSession(configuration: cfg)
}()

/// Asynchronously verify that a valid, up-to-date, actively sampling Pulse server is on `port`.
/// Never blocks the main thread; bounded to 1.0s.
func checkServerAlive(port: Int, timeout: TimeInterval = 1.0, completion: @escaping (Bool) -> Void) {
    let expectedMtime = expectedServerMtime()
    var req = URLRequest(url: urlForPort(port, "/api/snapshot"))
    req.cachePolicy = .reloadIgnoringLocalCacheData
    req.timeoutInterval = timeout
    let lock = NSLock()
    var finished = false
    let finish: (Bool) -> Void = { ok in
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        if !already {
            DispatchQueue.main.async { completion(ok) }
        }
    }
    let task = probeSession.dataTask(with: req) { data, resp, _ in
        var up = false
        if let h = resp as? HTTPURLResponse, h.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
           obj["apps"] != nil, obj["sys"] != nil {
            let freshEnough: Bool = {
                guard let t = (obj["t"] as? NSNumber)?.doubleValue else { return true }
                return abs(Date().timeIntervalSince1970 * 1000 - t) < 12_000
            }()
            if freshEnough {
                if let exp = expectedMtime {
                    if let got = obj["serverMtime"] as? Int, got == exp { up = true }
                } else {
                    up = true
                }
            }
        }
        finish(up)
    }
    task.resume()
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        task.cancel()
        finish(false)
    }
}

/* ================================================================== *
 *  LaunchAgent manager (~/Library/LaunchAgents/local.pulse.monitor.plist)
 * ================================================================== */
final class LaunchAgentManager {
    static let shared = LaunchAgentManager()
    let label: String
    let plistPath: String
    let domainTarget: String
    let serviceTarget: String
    let workQueue = DispatchQueue(label: "local.pulse.launchagent", qos: .userInitiated)
    var lastError: String?
    var cachedIsLoaded: Bool = false
    var isTransitioning: Bool = false

    init() {
        let lbl = isSelfTest ? "local.pulse.monitor.selftest" : "local.pulse.monitor"
        self.label = lbl
        self.plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(lbl).plist"
        let uid = getuid()
        self.domainTarget = "gui/\(uid)"
        self.serviceTarget = "gui/\(uid)/\(lbl)"
        self.cachedIsLoaded = FileManager.default.fileExists(atPath: self.plistPath)
        refreshStatusAsync()
    }

    var plistExists: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    func isLoaded() -> Bool {
        let (code, _) = runLaunchctl(["print", serviceTarget], timeout: 2.0)
        let ok = (code == 0)
        if Thread.isMainThread {
            cachedIsLoaded = ok
        } else {
            DispatchQueue.main.async { self.cachedIsLoaded = ok }
        }
        return ok
    }

    /// Non-blocking refresh of `cachedIsLoaded` on the serial background queue.
    func refreshStatusAsync(completion: ((Bool) -> Void)? = nil) {
        workQueue.async {
            let (code, _) = self.runLaunchctl(["print", self.serviceTarget], timeout: 2.0)
            let ok = (code == 0)
            DispatchQueue.main.async {
                self.cachedIsLoaded = ok
                completion?(ok)
            }
        }
    }

    /// Fast, non-blocking user-facing state for the "Start at login" toggle (never spawns launchctl on the main thread).
    func actualStartAtLoginState() -> Bool {
        cachedIsLoaded || plistExists
    }

    private func currentBundleVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.1"
    }

    private func expectedProgramArgs(nodePath: String) -> [String] {
        [nodePath, serverScriptPath()]
    }

    /// True if the plist on disk points to an older bundle path or older app version (e.g. post-Sparkle update).
    func needsPlistRefresh(nodePath: String) -> Bool {
        guard let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else { return true }
        let args = dict["ProgramArguments"] as? [String] ?? []
        let env = dict["EnvironmentVariables"] as? [String: String] ?? [:]
        if args != expectedProgramArgs(nodePath: nodePath) { return true }
        if env["PULSE_VERSION"] != currentBundleVersion() { return true }
        return false
    }

    private func writePlist(nodePath: String) throws {
        let agentsDir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: pulseDir, withIntermediateDirectories: true)

        var env: [String: String] = [
            "PULSE": "1",
            "PULSE_DAEMON": "1",
            "PORT": "0",
            "NODE_OPTIONS": "--max-old-space-size=64 --max-semi-space-size=8",
            "PULSE_VERSION": currentBundleVersion(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if isSelfTest {
            env["PULSE_SELFTEST"] = "1"
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": expectedProgramArgs(nodePath: nodePath),
            "EnvironmentVariables": env,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": pulseDir + (isSelfTest ? "/daemon-selftest.log" : "/daemon.log"),
            "StandardErrorPath": "/dev/null",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }

    @discardableResult
    func runLaunchctl(_ args: [String], timeout: TimeInterval = 4.0) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        do {
            try p.run()
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning {
                p.terminate()
                return (-1, "launchctl timed out")
            }
            p.waitUntilExit()
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (p.terminationStatus, errStr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    /// Install (or update) the LaunchAgent plist and bootstrap it into the user's GUI launchd domain.
    /// Note: RunAtLoad=true in the plist starts the daemon automatically on bootstrap; do not kickstart -k after bootstrap.
    func installAndBootstrap(nodePath: String) -> Result<Void, Error> {
        do {
            try writePlist(nodePath: nodePath)
        } catch {
            let msg = "Could not write LaunchAgent plist: \(error.localizedDescription)"
            lastError = msg
            return .failure(NSError(domain: "PulseLaunchAgent", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        // Unload any prior instance first (ignore error if not currently loaded).
        _ = runLaunchctl(["bootout", serviceTarget])
        usleep(40_000)
        let (code, err) = runLaunchctl(["bootstrap", domainTarget, plistPath])
        if code != 0 && !isLoaded() {
            // Clean up plist if bootstrap failed in a non-GUI/unsupported session so state stays honest.
            try? FileManager.default.removeItem(atPath: plistPath)
            let msg = err.isEmpty ? "launchctl bootstrap exited with code \(code)" : err
            lastError = msg
            if Thread.isMainThread { cachedIsLoaded = false }
            else { DispatchQueue.main.async { self.cachedIsLoaded = false } }
            return .failure(NSError(domain: "PulseLaunchAgent", code: Int(code),
                                    userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        lastError = nil
        if Thread.isMainThread { cachedIsLoaded = true }
        else { DispatchQueue.main.async { self.cachedIsLoaded = true } }
        return .success(())
    }

    /// Stop the running daemon for this session without deleting the plist ("Quit Pulse & Stop Background", Sparkle relaunch).
    @discardableResult
    func bootoutSessionOnly() -> Bool {
        let (c1, _) = runLaunchctl(["bootout", serviceTarget])
        if c1 != 0 && plistExists {
            _ = runLaunchctl(["bootout", domainTarget, plistPath])
        }
        let stillLoaded = isLoaded()
        return !stillLoaded
    }

    /// Disable Start at login completely: unload LaunchAgent and remove the plist.
    func uninstall() -> Result<Void, Error> {
        _ = bootoutSessionOnly()
        do {
            if plistExists {
                try FileManager.default.removeItem(atPath: plistPath)
            }
            lastError = nil
            if Thread.isMainThread { cachedIsLoaded = false }
            else { DispatchQueue.main.async { self.cachedIsLoaded = false } }
            return .success(())
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }
}

/* ================================================================== *
 *  Menu-bar status item: live CPU + memory graphs + quick settings
 * ================================================================== */
final class StatusController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var cpuHist: [Double] = []
    var memHist: [Double] = []
    var lastRenderKey = ""
    var timer: Timer?
    var samples = 0
    var port: Int?
    var lastStatusT: Double = 0
    var pollFails = 0
    var lastPurgeId = 0  // dedupe: the `purge` flag stays in /api/status until settled
    var onStaleBackend: (() -> Void)?

    let cpuItem = NSMenuItem(title: "CPU —", action: nil, keyEquivalent: "")
    let memItem = NSMenuItem(title: "Memory —", action: nil, keyEquivalent: "")
    let topCpuItem = NSMenuItem(title: "Top CPU —", action: nil, keyEquivalent: "")
    let topMemItem = NSMenuItem(title: "Top Memory —", action: nil, keyEquivalent: "")

    let startAtLoginItem = NSMenuItem(title: "Start at Login", action: #selector(Shell.toggleStartAtLoginMenu), keyEquivalent: "")
    let keepRunningItem = NSMenuItem(title: "Keep Running When Closed", action: #selector(Shell.toggleKeepRunningMenu), keyEquivalent: "")
    let keepMemItem = NSMenuItem(title: "Keep Dashboard in Memory", action: #selector(Shell.toggleKeepDashboardInMemoryMenu), keyEquivalent: "")
    let daemonErrorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let settingsItem = NSMenuItem(title: "Settings…", action: #selector(Shell.openSettings), keyEquivalent: ",")
    let openItem = NSMenuItem(title: "Open Pulse", action: #selector(Shell.openApp), keyEquivalent: "")
    let quitItem = NSMenuItem(title: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    let quitAndStopBgItem = NSMenuItem(title: "Quit Pulse & Stop Background", action: #selector(Shell.quitAndStopBackground), keyEquivalent: "")

    weak var shell: Shell?

    init(shell: Shell) {
        self.shell = shell
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let title = NSMenuItem(title: "Pulse v\(ver)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        for mi in [cpuItem, memItem, topCpuItem, topMemItem] {
            mi.isEnabled = false
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        for mi in [startAtLoginItem, keepRunningItem, keepMemItem, settingsItem, openItem, quitAndStopBgItem] {
            mi.target = shell
        }
        daemonErrorItem.isEnabled = false
        daemonErrorItem.isHidden = true
        menu.addItem(startAtLoginItem)
        menu.addItem(keepRunningItem)
        menu.addItem(keepMemItem)
        menu.addItem(daemonErrorItem)
        menu.addItem(.separator())
        menu.addItem(openItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        quitAndStopBgItem.isHidden = true
        menu.addItem(quitAndStopBgItem)

        item.menu = menu
        item.button?.image = Self.render(cpu: [], mem: [])
        refreshToggleStates(queryLaunchctl: false)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshToggleStates(queryLaunchctl: false)
        LaunchAgentManager.shared.refreshStatusAsync { [weak self] _ in
            self?.refreshToggleStates(queryLaunchctl: false)
        }
    }

    func refreshToggleStates(queryLaunchctl: Bool = false) {
        guard let shell else { return }
        let mgr = LaunchAgentManager.shared
        let daemonActive = queryLaunchctl ? mgr.isLoaded() : mgr.cachedIsLoaded
        let loginOn = mgr.isTransitioning ? shell.settings.startAtLogin : (daemonActive || mgr.plistExists)
        startAtLoginItem.state = loginOn ? .on : .off
        keepRunningItem.state = shell.settings.shouldQuitOnClose ? .off : .on
        keepMemItem.state = shell.settings.keepDashboardInMemory ? .on : .off
        quitAndStopBgItem.isHidden = !daemonActive
        if let err = mgr.lastError, !err.isEmpty {
            daemonErrorItem.title = "Background error: \(err.prefix(48))"
            daemonErrorItem.isHidden = false
        } else {
            daemonErrorItem.isHidden = true
        }
    }

    func start(port: Int) {
        let first = (self.port == nil)
        self.port = port
        poll()
        if first {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        }
    }

    func poll() {
        guard let port else { return }
        var req = URLRequest(url: urlForPort(port, "/api/status"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
            else {
                DispatchQueue.main.async {
                    self.pollFails += 1
                    if self.pollFails >= 3 {
                        self.pollFails = 0
                        self.onStaleBackend?()
                    }
                }
                return
            }
            DispatchQueue.main.async {
                self.pollFails = 0
                guard obj["cpu"] != nil else { return } // still warming up (<250ms after spawn)
                if let diskMtime = expectedServerMtime(), (obj["serverMtime"] as? Int) != diskMtime {
                    self.onStaleBackend?()
                    return
                }
                let snapT = (obj["t"] as? NSNumber)?.doubleValue ?? 0
                if snapT > 0 && abs(Date().timeIntervalSince1970 * 1000 - snapT) > 15_000 {
                    self.onStaleBackend?()
                    return
                }
                self.samples += 1
                BootTracer.shared.markBackendTrace(obj["bootTrace"] as? [String: Any])
                BootTracer.shared.mark("menubar_first_sample", once: true, launchOnly: true)
                if snapT == 0 || snapT > self.lastStatusT {
                    if snapT > 0 { self.lastStatusT = snapT }
                    if let c = obj["cpu"] as? [String: Any], let t = c["total"] as? Double {
                        self.cpuHist.append(t)
                    }
                    if let m = obj["memPct"] as? Double { self.memHist.append(m) }
                    if self.cpuHist.count > 40 { self.cpuHist.removeFirst(self.cpuHist.count - 40) }
                    if self.memHist.count > 40 { self.memHist.removeFirst(self.memHist.count - 40) }
                }
                let key = Self.renderKey(cpu: self.cpuHist, mem: self.memHist)
                if key != self.lastRenderKey {
                    self.lastRenderKey = key
                    self.item.button?.image = Self.render(cpu: self.cpuHist, mem: self.memHist)
                }
                self.updateMenu(obj)
                if let pid = obj["purge"] as? Int, pid != self.lastPurgeId {
                    self.lastPurgeId = pid
                    let p = self.port
                    DispatchQueue.global(qos: .userInitiated).async { self.runPurge(id: pid, port: p) }
                }
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

    func runPurge(id: Int, port: Int?) {
        guard let port else { return }
        var err: NSDictionary?
        NSAppleScript(source: Self.purgeScript)?.executeAndReturnError(&err)
        var ok = false
        var cancelled = false
        if let e = err {
            let code = (e["errAENumber"] as? Int) ?? (e["NSAppleErrNumber"] as? Int) ?? 0
            let msg = ((e["errAEError"] as? String) ?? "") + " " +
                      ((e["NSAppleErrAEError"] as? String) ?? "")
            cancelled = code == -128 || msg.lowercased().contains("cancel")
        } else { ok = true }
        let payload: [String: Any] = ["id": id, "ok": ok, "cancelled": cancelled]
        var req = URLRequest(url: urlForPort(port, "/api/purge-result"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    static let purgeScript =
        "do shell script \"/usr/sbin/purge\" with prompt \"Pulse wants to clear the disk cache. " +
        "You will be asked for Touch ID or your password.\" with administrator privileges"

    static func renderKey(cpu: [Double], mem: [Double]) -> String {
        let cBucket = Int(((min(max(cpu.last ?? 0, 0), 100) / 100.0) * 36.0).rounded())
        let mBucket = Int(((min(max(mem.last ?? 0, 0), 100) / 100.0) * 36.0).rounded())
        return "\(cBucket):\(mBucket)"
    }

    static func render(cpu: [Double], mem: [Double]) -> NSImage {
        renderBars(cpu: cpu.last, mem: mem.last)
    }

    static func renderBars(cpu: Double?, mem: Double?) -> NSImage {
        let w: CGFloat = 54, h: CGFloat = 22
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
        let barW: CGFloat = 9, barH: CGFloat = 18
        let barY: CGFloat = (h - barH) / 2
        let cellW: CGFloat = 7
        let letterAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 6.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        func metric(_ x: CGFloat, _ label: String, _ value: Double?, _ color: NSColor) {
            let lineH = barH / CGFloat(label.count)
            for (j, ch) in label.enumerated() {
                let s = String(ch) as NSString
                let sz = s.size(withAttributes: letterAttrs)
                let cellY = barY + barH - lineH * CGFloat(j + 1)
                s.draw(
                    at: NSPoint(x: x + (cellW - sz.width) / 2,
                                y: cellY + (lineH - sz.height) / 2),
                    withAttributes: letterAttrs)
            }
            let bx = x + 8
            let cr: CGFloat = 2
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1)
            NSBezierPath(roundedRect: NSRect(x: bx, y: barY, width: barW, height: barH),
                         xRadius: cr, yRadius: cr).stroke()
            if let v = value, v > 0 {
                let fh = CGFloat(min(v, 100) / 100) * barH
                if fh > 0 {
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
 *  Weak wrapper so WKUserContentController never retains Shell/WKWebView
 * ================================================================== */
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/* ================================================================== *
 *  Native AppKit Settings panel (used when dashboard window is closed)
 *  Styled to match Pulse's dark card UI (#0b0d12 / #171b25 / #232a38)
 * ================================================================== */
final class SettingsWindowController: NSObject {
    weak var shell: Shell?
    let window: NSWindow
    let startAtLoginSwitch = NSSwitch()
    let loginStatusLabel = NSTextField(labelWithString: "")
    let closeBehaviorSeg: NSSegmentedControl
    let keepMemSwitch = NSSwitch()

    private let panelBg = NSColor(red: 0.071, green: 0.082, blue: 0.114, alpha: 1)  // #12151d
    private let cardBg = NSColor(red: 0.090, green: 0.106, blue: 0.145, alpha: 1)   // #171b25
    private let borderCol = NSColor(red: 0.137, green: 0.165, blue: 0.220, alpha: 1) // #232a38
    private let textCol = NSColor(red: 0.910, green: 0.925, blue: 0.957, alpha: 1)   // #e8ecf4
    private let dimCol = NSColor(red: 0.545, green: 0.580, blue: 0.655, alpha: 1)    // #8b94a7
    private let accentGreen = NSColor(red: 0.176, green: 0.831, blue: 0.655, alpha: 1) // #2dd4a7
    private let accentOrange = NSColor(red: 1.0, green: 0.624, blue: 0.263, alpha: 1)  // #ff9f43

    init(shell: Shell) {
        self.shell = shell
        let rect = NSRect(x: 0, y: 0, width: 468, height: 318)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Pulse Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = panelBg
        window.isReleasedWhenClosed = false
        window.center()

        closeBehaviorSeg = NSSegmentedControl(labels: ["Keep in Menu Bar", "Quit Pulse"],
                                              trackingMode: .selectOne,
                                              target: nil,
                                              action: nil)
        super.init()

        startAtLoginSwitch.target = self
        startAtLoginSwitch.action = #selector(onStartAtLoginChanged)
        closeBehaviorSeg.target = self
        closeBehaviorSeg.action = #selector(onCloseBehaviorChanged)
        keepMemSwitch.target = self
        keepMemSwitch.action = #selector(onKeepMemChanged)

        buildLayout()
        syncFromState()
    }

    private func makeTitle(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = textCol
        return lbl
    }

    private func makeNote(_ text: String) -> NSTextField {
        let lbl = NSTextField(wrappingLabelWithString: text)
        lbl.font = .systemFont(ofSize: 11.5)
        lbl.textColor = dimCol
        lbl.maximumNumberOfLines = 3
        return lbl
    }

    private func makeCard(_ inner: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = cardBg.cgColor
        box.layer?.borderColor = borderCol.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
        ])
        return box
    }

    private func buildLayout() {
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.wantsLayer = true
        content.layer?.backgroundColor = panelBg.cgColor
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        // 1. Start at login card
        let s1Left = NSStackView()
        s1Left.orientation = .vertical
        s1Left.alignment = .leading
        s1Left.spacing = 3
        let s1Header = NSStackView()
        s1Header.orientation = .horizontal
        s1Header.alignment = .centerY
        s1Header.spacing = 8
        loginStatusLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        s1Header.addArrangedSubview(makeTitle("Start at login"))
        s1Header.addArrangedSubview(loginStatusLabel)
        s1Left.addArrangedSubview(s1Header)
        s1Left.addArrangedSubview(makeNote("Runs the sampler via a macOS LaunchAgent so metrics are already warm when you open Pulse."))

        let s1Row = NSStackView(views: [s1Left, startAtLoginSwitch])
        s1Row.orientation = .horizontal
        s1Row.alignment = .top
        s1Row.distribution = .fill
        s1Row.spacing = 14
        startAtLoginSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let card1 = makeCard(s1Row)

        // 2. When window closes card
        let s2Col = NSStackView()
        s2Col.orientation = .vertical
        s2Col.alignment = .leading
        s2Col.spacing = 6
        s2Col.addArrangedSubview(makeTitle("When the window is closed"))
        s2Col.addArrangedSubview(makeNote("Keep Pulse in your menu bar with live CPU & memory bars, or quit completely on ⌘W."))
        closeBehaviorSeg.segmentDistribution = .fillEqually
        closeBehaviorSeg.translatesAutoresizingMaskIntoConstraints = false
        s2Col.addArrangedSubview(closeBehaviorSeg)
        NSLayoutConstraint.activate([
            closeBehaviorSeg.widthAnchor.constraint(equalTo: s2Col.widthAnchor),
        ])
        let card2 = makeCard(s2Col)

        // 3. Keep dashboard in memory card
        let s3Left = NSStackView()
        s3Left.orientation = .vertical
        s3Left.alignment = .leading
        s3Left.spacing = 3
        s3Left.addArrangedSubview(makeTitle("Keep dashboard in memory when closed"))
        s3Left.addArrangedSubview(makeNote("When off, closing the window releases WebKit rendering processes (~120 MB) and reloads (<0.5s) on reopen."))

        let s3Row = NSStackView(views: [s3Left, keepMemSwitch])
        s3Row.orientation = .horizontal
        s3Row.alignment = .top
        s3Row.distribution = .fill
        s3Row.spacing = 14
        keepMemSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let card3 = makeCard(s3Row)

        for card in [card1, card2, card3] {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
        ])
    }

    func syncFromState() {
        guard let shell else { return }
        let mgr = LaunchAgentManager.shared
        let loaded = mgr.cachedIsLoaded
        let configured = mgr.isTransitioning ? shell.settings.startAtLogin : (loaded || mgr.plistExists)
        startAtLoginSwitch.state = configured ? .on : .off
        if let err = mgr.lastError, !err.isEmpty {
            loginStatusLabel.stringValue = "● Error: \(err.prefix(34))"
            loginStatusLabel.textColor = .systemRed
        } else if mgr.isTransitioning {
            loginStatusLabel.stringValue = "● Applying…"
            loginStatusLabel.textColor = accentOrange
        } else if loaded || configured {
            loginStatusLabel.stringValue = "● Active"
            loginStatusLabel.textColor = accentGreen
        } else {
            loginStatusLabel.stringValue = "● Off"
            loginStatusLabel.textColor = dimCol
        }
        closeBehaviorSeg.selectedSegment = shell.settings.shouldQuitOnClose ? 1 : 0
        keepMemSwitch.state = shell.settings.keepDashboardInMemory ? .on : .off
    }

    func show() {
        syncFromState()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func onStartAtLoginChanged() {
        shell?.setStartAtLogin(startAtLoginSwitch.state == .on)
    }

    @objc func onCloseBehaviorChanged() {
        let mode = (closeBehaviorSeg.selectedSegment == 1) ? "quit" : "background"
        shell?.setCloseBehavior(mode)
    }

    @objc func onKeepMemChanged() {
        shell?.setKeepDashboardInMemory(keepMemSwitch.state == .on)
    }
}

/* ================================================================== *
 *  App shell
 * ================================================================== */
final class Shell: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, SPUUpdaterDelegate {
    var window: NSWindow!
    var web: WKWebView?
    var settings = PulseSettings()
    var settingsController: SettingsWindowController?
    var nodeProc: Process?
    var spawnedNode = false
    var restartingBackend = false
    var switchingBackend = false
    var lastBackendMtime: Int?
    var quitting = false
    var loaded = false
    var serverPort: Int?
    var status: StatusController?
    var updater: SPUStandardUpdaterController!
    var activityToken: NSObjectProtocol?
    let darkBg = NSColor(red: 0.043, green: 0.055, blue: 0.07, alpha: 1)

    @objc func reload() {
        if spawnedNode, let disk = expectedServerMtime(), disk != lastBackendMtime {
            restartSpawnedBackend()
        } else {
            web?.reload()
        }
    }

    @objc func findInPage() {
        guard window.isVisible else { return }
        web?.evaluateJavaScript("(() => { const s = document.getElementById('search'); if (s) { s.focus(); s.select(); } })()", completionHandler: nil)
    }

    @discardableResult
    func ensureWebView() -> WKWebView {
        if let existing = web { return existing }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let handler = WeakScriptMessageHandler(self)
        cfg.userContentController.add(handler, name: "pulseTrace")
        cfg.userContentController.add(handler, name: "pulseSettings")
        let w = WKWebView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: cfg)
        w.navigationDelegate = self
        w.uiDelegate = self
        if #available(macOS 12.0, *) {
            w.underPageBackgroundColor = darkBg
        }
        window.contentView = w
        web = w
        return w
    }

    func releaseWebView() {
        guard let w = web else { return }
        w.stopLoading()
        w.configuration.userContentController.removeScriptMessageHandler(forName: "pulseTrace")
        w.configuration.userContentController.removeScriptMessageHandler(forName: "pulseSettings")
        w.navigationDelegate = nil
        w.uiDelegate = nil
        let placeholder = NSView(frame: window.contentView?.bounds ?? .zero)
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = darkBg.cgColor
        window.contentView = placeholder
        web = nil
        loaded = false
    }

    func loadDashboard(port: Int) {
        let w = ensureWebView()
        loaded = true
        BootTracer.shared.mark("webview_load")
        let path = "/?r=\(Int(Date().timeIntervalSince1970 * 1000))"
        w.load(URLRequest(url: urlForPort(port, path)))
    }

    @objc func openApp() {
        let wasHidden = !window.isVisible
        let hadWarmWeb = (web != nil && loaded)
        if wasHidden {
            BootTracer.shared.beginSession(mode: "reopen", extra: "warm_webview=\(hadWarmWeb)")
            BootTracer.shared.mark("window_reopen")
        }
        _ = ensureWebView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !loaded, let port = serverPort {
            loadDashboard(port: port)
        } else if hadWarmWeb {
            web?.evaluateJavaScript("window.__pulseWake && window.__pulseWake()") { _, _ in
                if wasHidden { BootTracer.shared.mark("first_render", once: true) }
            }
        }
    }

    @objc func openSettings() {
        if window.isVisible, let w = web, loaded {
            settingsController?.window.close()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            pushSettingsToWeb()
            w.evaluateJavaScript("window.__pulseOpenSettings && window.__pulseOpenSettings()", completionHandler: nil)
            return
        }
        openNativeSettings()
    }

    func openNativeSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(shell: self)
        }
        settingsController?.show()
    }

    func currentSettingsPayload() -> [String: Any] {
        let mgr = LaunchAgentManager.shared
        let configured = mgr.isTransitioning ? settings.startAtLogin : (mgr.cachedIsLoaded || mgr.plistExists)
        let daemonStatus: String
        if let err = mgr.lastError, !err.isEmpty {
            daemonStatus = "error"
        } else if mgr.isTransitioning {
            daemonStatus = "busy"
        } else if mgr.cachedIsLoaded {
            daemonStatus = "active"
        } else if mgr.plistExists {
            daemonStatus = "stopped"
        } else {
            daemonStatus = "off"
        }
        return [
            "startAtLogin": configured,
            "closeBehavior": settings.closeBehavior,
            "keepDashboardInMemory": settings.keepDashboardInMemory,
            "daemonStatus": daemonStatus,
            "daemonError": mgr.lastError ?? "",
        ]
    }

    func pushSettingsToWeb() {
        guard let w = web, loaded,
              let data = try? JSONSerialization.data(withJSONObject: currentSettingsPayload()),
              let json = String(data: data, encoding: .utf8) else { return }
        w.evaluateJavaScript("window.__pulseSyncSettings && window.__pulseSyncSettings(\(json))", completionHandler: nil)
    }

    func syncAllSettingsUI() {
        status?.refreshToggleStates(queryLaunchctl: false)
        settingsController?.syncFromState()
        pushSettingsToWeb()
    }

    @objc func toggleStartAtLoginMenu() {
        let mgr = LaunchAgentManager.shared
        let currentlyOn = mgr.isTransitioning ? settings.startAtLogin : mgr.actualStartAtLoginState()
        setStartAtLogin(!currentlyOn)
    }

    @objc func toggleKeepRunningMenu() {
        setCloseBehavior(settings.shouldQuitOnClose ? "background" : "quit")
    }

    @objc func toggleKeepDashboardInMemoryMenu() {
        setKeepDashboardInMemory(!settings.keepDashboardInMemory)
    }

    func setCloseBehavior(_ mode: String) {
        settings.closeBehavior = (mode == "quit") ? "quit" : "background"
        settings.save()
        syncAllSettingsUI()
    }

    func setKeepDashboardInMemory(_ keep: Bool) {
        settings.keepDashboardInMemory = keep
        settings.save()
        if !keep && !window.isVisible {
            releaseWebView()
        }
        syncAllSettingsUI()
    }

    func setStartAtLogin(_ enabled: Bool) {
        let mgr = LaunchAgentManager.shared
        mgr.lastError = nil
        mgr.isTransitioning = true
        switchingBackend = true
        settings.startAtLogin = enabled
        settings.save()
        syncAllSettingsUI()

        if enabled {
            findNodeAsync { [weak self] node in
                guard let self else { return }
                guard let node else {
                    mgr.isTransitioning = false
                    self.switchingBackend = false
                    mgr.lastError = "Node.js not found"
                    self.settings.startAtLogin = false
                    self.settings.save()
                    self.syncAllSettingsUI()
                    return
                }
                // Stop our app-spawned backend and hand its port to the LaunchAgent via ~/.pulse/preferred-port
                // so the dashboard stays on the exact same origin without reloading WKWebView.
                let oldPort = self.serverPort
                if let oldPort, oldPort > 0 {
                    try? FileManager.default.createDirectory(atPath: pulseDir, withIntermediateDirectories: true)
                    try? "\(oldPort)\n".write(toFile: pulseDir + "/preferred-port", atomically: true, encoding: .utf8)
                }
                let dyingProc: Process? = self.spawnedNode ? self.nodeProc : nil
                if self.spawnedNode, let p = self.nodeProc {
                    self.nodeProc = nil
                    self.spawnedNode = false
                    try? FileManager.default.removeItem(atPath: pulseDir + "/port")
                    if p.isRunning { p.terminate() }
                }
                mgr.workQueue.async { [weak self] in
                    if let dp = dyingProc {
                        let deadline = Date().addingTimeInterval(0.25)
                        while dp.isRunning && Date() < deadline { usleep(15_000) }
                    }
                    let result = mgr.installAndBootstrap(nodePath: node)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        mgr.isTransitioning = false
                        switch result {
                        case .success:
                            self.settings.startAtLogin = true
                            self.settings.save()
                            self.syncAllSettingsUI()
                            self.attachToDaemonPort(attemptsLeft: 25)
                        case .failure:
                            try? FileManager.default.removeItem(atPath: pulseDir + "/preferred-port")
                            self.switchingBackend = false
                            self.settings.startAtLogin = false
                            self.settings.save()
                            self.syncAllSettingsUI()
                            if self.serverPort == nil || !self.spawnedNode {
                                self.spawnBackend(portOverride: oldPort)
                            }
                        }
                    }
                }
            }
        } else {
            let wasDaemonOwned = !spawnedNode
            let oldPort = serverPort
            if wasDaemonOwned {
                try? FileManager.default.removeItem(atPath: pulseDir + "/port")
            }
            mgr.workQueue.async { [weak self] in
                _ = mgr.uninstall()
                DispatchQueue.main.async {
                    guard let self else { return }
                    mgr.isTransitioning = false
                    self.settings.startAtLogin = false
                    self.settings.save()
                    self.syncAllSettingsUI()
                    // Keep Pulse working for the rest of the current session via an app-owned backend on the same port.
                    if wasDaemonOwned && !self.quitting && !isSelfTest {
                        self.spawnBackend(portOverride: oldPort)
                    } else {
                        self.switchingBackend = false
                    }
                }
            }
        }
    }

    private func attachToDaemonPort(attemptsLeft: Int) {
        if let p = readPortFile() {
            checkServerAlive(port: p, timeout: 0.6) { [weak self] alive in
                guard let self, !self.quitting else { return }
                if alive {
                    let samePortAndLoaded = (self.serverPort == p && self.loaded)
                    self.switchingBackend = false
                    self.serverPort = p
                    self.spawnedNode = false
                    self.status?.start(port: p)
                    self.syncAllSettingsUI()
                    if self.window.isVisible {
                        if samePortAndLoaded {
                            self.web?.evaluateJavaScript("window.__pulseWake && window.__pulseWake()", completionHandler: nil)
                        } else {
                            self.loadDashboard(port: p)
                        }
                    }
                    return
                }
                if attemptsLeft > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        self.attachToDaemonPort(attemptsLeft: attemptsLeft - 1)
                    }
                } else {
                    // Fallback so UI never stays disconnected if launchd couldn't spawn in this session
                    self.switchingBackend = false
                    self.spawnBackend(portOverride: nil)
                }
            }
        } else if attemptsLeft > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.attachToDaemonPort(attemptsLeft: attemptsLeft - 1)
            }
        } else {
            switchingBackend = false
            spawnBackend(portOverride: nil)
        }
    }

    @objc func quitAndStopBackground() {
        quitting = true
        _ = LaunchAgentManager.shared.bootoutSessionOnly()
        NSApp.terminate(nil)
    }

    @objc func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    // MARK: Sparkle delegate — restart LaunchAgent on auto-update so it never serves an old bundle
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        quitting = true
        if LaunchAgentManager.shared.cachedIsLoaded || LaunchAgentManager.shared.plistExists {
            _ = LaunchAgentManager.shared.bootoutSessionOnly()
        }
    }

    // MARK: WKScriptMessageHandler — receive page trace stages & in-dashboard settings changes
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "pulseTrace" {
            guard let body = message.body as? [String: Any],
                  let stage = body["stage"] as? String else { return }
            let allowed: Set<String> = ["dom_content_loaded", "first_sse_message", "first_render"]
            guard allowed.contains(stage) else { return }
            let ts = (body["t"] as? NSNumber)?.int64Value
            BootTracer.shared.mark(stage, tsOverrideMs: ts, once: true)
            return
        }
        if message.name == "pulseSettings" {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            switch action {
            case "sync":
                pushSettingsToWeb()
                LaunchAgentManager.shared.refreshStatusAsync { [weak self] _ in
                    self?.syncAllSettingsUI()
                }
            case "setStartAtLogin":
                if let val = body["value"] as? Bool { setStartAtLogin(val) }
            case "setCloseBehavior":
                if let val = body["value"] as? String { setCloseBehavior(val) }
            case "setKeepDashboardInMemory":
                if let val = body["value"] as? Bool { setKeepDashboardInMemory(val) }
            default:
                break
            }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        BootTracer.shared.beginSession(mode: "launch", extra: "daemon=\(LaunchAgentManager.shared.plistExists ? "configured" : "off")")
        BootTracer.shared.mark("app_launch")

        // Single instance: if another Pulse is already running, ask it to reopen its window, focus it, and exit.
        if !isSelfTest,
           let bid = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(
                reopenNotificationName, object: nil, userInfo: nil, deliverImmediately: true
            )
            other.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onExternalReopen(_:)), name: reopenNotificationName, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onExternalCloseWindow(_:)), name: closeWindowNotificationName, object: nil
        )

        let rect = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Pulse"
        window.minSize = NSSize(width: 940, height: 620)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = darkBg

        // Kick off backend discovery / spawn immediately so it runs in parallel with
        // WKWebView, menu bar, and Sparkle initialization on the main thread.
        status = StatusController(shell: self)
        status?.onStaleBackend = { [weak self] in self?.handleStaleBackend() }
        startServer()

        _ = ensureWebView()

        // Main menu: App (About, Settings Cmd-,, Updates, Quit Cmd-Q), Edit (Copy/Paste/Find), View (Reload), Window (Close Cmd-W).
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pulse",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
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
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find…", action: #selector(findInPage), keyEquivalent: "f")
        findItem.target = self
        editMenu.addItem(findItem)
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let reloadItem = NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem(); mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let port = serverPort, !loaded {
            loadDashboard(port: port)
        }

        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

        // Prevent App Nap from throttling live menu-bar polling & sampling while
        // Pulse is behind other windows or closed to the menu bar, without blocking idle sleep.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Live system resource monitoring"
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.status?.poll()
            self?.web?.evaluateJavaScript("window.__pulseWake && window.__pulseWake()", completionHandler: nil)
        }
    }

    @objc func onExternalReopen(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.openApp()
        }
    }

    @objc func onExternalCloseWindow(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.window.performClose(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible {
            openApp()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        if quitting { return }
        if settings.shouldQuitOnClose {
            NSApp.terminate(nil)
            return
        }
        if !settings.keepDashboardInMemory {
            releaseWebView()
        }
    }

    /// Reuse a running backend (port file / $PULSE_PORT / LaunchAgent) asynchronously, or spawn one on a dynamic port.
    func startServer() {
        if let forced = ProcessInfo.processInfo.environment["PULSE_PORT"].flatMap({ Int($0) }) {
            BootTracer.shared.mark("port_probe_start")
            checkServerAlive(port: forced, timeout: 1.0) { [weak self] alive in
                guard let self else { return }
                if alive {
                    BootTracer.shared.mark("daemon_reused")
                    self.serverPort = forced
                    self.beginService()
                } else {
                    self.spawnBackend(portOverride: forced)
                }
            }
            return
        }
        if isSelfTest {
            spawnBackend(portOverride: 0)
            return
        }

        let agent = LaunchAgentManager.shared
        if let p = readPortFile() {
            BootTracer.shared.mark("port_probe_start")
            checkServerAlive(port: p, timeout: 1.0) { [weak self] alive in
                guard let self else { return }
                if alive {
                    BootTracer.shared.mark("daemon_reused")
                    self.serverPort = p
                    self.spawnedNode = false
                    self.beginService()
                    return
                }
                // Port file was stale or serverMtime changed (e.g. Sparkle upgrade or rebuild).
                if agent.plistExists {
                    self.refreshDaemonOrSpawn()
                } else {
                    self.spawnBackend(portOverride: nil)
                }
            }
            return
        }

        if agent.plistExists {
            refreshDaemonOrSpawn()
        } else {
            spawnBackend(portOverride: nil)
        }
    }

    private func refreshDaemonOrSpawn() {
        findNodeAsync { [weak self] node in
            guard let self else { return }
            guard let node else {
                self.spawnBackend(portOverride: nil)
                return
            }
            let agent = LaunchAgentManager.shared
            self.switchingBackend = true
            agent.workQueue.async { [weak self] in
                let needsInstall = agent.needsPlistRefresh(nodePath: node) || !agent.isLoaded()
                if needsInstall {
                    let res = agent.installAndBootstrap(nodePath: node)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch res {
                        case .success:
                            self.attachToDaemonPort(attemptsLeft: 25)
                        case .failure:
                            self.switchingBackend = false
                            self.spawnBackend(portOverride: nil)
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        // Daemon is loaded with current plist (e.g. still finishing its first sample right after boot).
                        self?.attachToDaemonPort(attemptsLeft: 20)
                    }
                }
            }
        }
    }

    func handleStaleBackend() {
        guard !quitting, !switchingBackend else { return }
        if spawnedNode {
            restartSpawnedBackend()
        } else if LaunchAgentManager.shared.plistExists {
            loaded = false
            refreshDaemonOrSpawn()
        } else {
            loaded = false
            spawnBackend(portOverride: nil)
        }
    }

    func restartSpawnedBackend() {
        guard spawnedNode, !quitting, !restartingBackend else { return }
        restartingBackend = true
        if let old = nodeProc {
            nodeProc = nil
            if old.isRunning { old.terminate() }
        }
        serverPort = nil
        loaded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.quitting else { return }
            self.restartingBackend = false
            self.spawnBackend(portOverride: nil)
        }
    }

    func spawnBackend(portOverride: Int?) {
        BootTracer.shared.mark("backend_spawn")
        findNodeAsync { [weak self] node in
            guard let self, !self.quitting else { return }
            guard let node else {
                self.switchingBackend = false
                self.showFatal("Node.js was not found.\nInstall it (brew install node) or set PULSE_NODE=/path/to/node, then reopen Pulse.")
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = [serverScriptPath()]
            var env = ProcessInfo.processInfo.environment
            env["PULSE"] = "1"
            env["PORT"] = portOverride.map(String.init) ?? "0"
            env["NODE_OPTIONS"] = "--max-old-space-size=64 --max-semi-space-size=8"
            if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                env["PULSE_VERSION"] = v
            }
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { [weak self] proc in
                DispatchQueue.main.async {
                    guard let self, !self.quitting, proc === self.nodeProc else { return }
                    if proc.terminationReason == .uncaughtSignal || proc.terminationStatus != 0 {
                        self.showFatal("The Pulse backend exited unexpectedly (status \(proc.terminationStatus)).\nReopen the app to try again.")
                    }
                }
            }
            do {
                try p.run()
                self.nodeProc = p
                self.spawnedNode = true
                self.lastBackendMtime = expectedServerMtime()
            } catch {
                self.switchingBackend = false
                self.showFatal("Could not start the Pulse backend:\n\(error.localizedDescription)")
                return
            }
            DispatchQueue.global().async { [weak self] in
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    guard let s = String(data: data, encoding: .utf8) else { continue }
                    for line in s.components(separatedBy: "\n") where line.hasPrefix("PULSE_LISTENING=") {
                        if let port = Int(line.dropFirst("PULSE_LISTENING=".count)) {
                            DispatchQueue.main.async {
                                guard let self else { return }
                                BootTracer.shared.mark("pulse_listening", once: true)
                                let samePortAndLoaded = (self.serverPort == port && self.loaded)
                                self.switchingBackend = false
                                self.serverPort = port
                                if samePortAndLoaded {
                                    self.status?.start(port: port)
                                    self.syncAllSettingsUI()
                                    if self.window.isVisible {
                                        self.web?.evaluateJavaScript("window.__pulseWake && window.__pulseWake()", completionHandler: nil)
                                    }
                                } else {
                                    self.loaded = false
                                    self.beginService()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func beginService() {
        guard let port = serverPort, !loaded else { return }
        if window.isVisible {
            loadDashboard(port: port)
        }
        status?.start(port: port)
        if isSelfTest {
            scheduleSelfTest()
        }
    }

    // MARK: Self-test (DOM + confirm + popover + lifecycle: close/reopen, settings migration/round-trip, LaunchAgent)
    private func scheduleSelfTest() {
        Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            self?.runSelfTest()
        }
    }

    private func runSelfTest() {
        // NOTE: evaluateJavaScript is synchronous on DOM expressions here.
        let js = """
        (() => {
          let confirmWired = null;
          if (window.__autoconfirm) confirmWired = confirm('selftest');
          const row = [...document.querySelectorAll('#rows-cpu .row')].find(r => r.style.display !== 'none');
          if (row) row.click();
          const drawerRows = document.querySelectorAll('#dtable .prow').length;
          document.querySelector('#dclose')?.click();
          document.querySelector('#mem-info')?.click();
          const memInfo = {
            open: !document.querySelector('#mempop')?.hidden,
            wired: document.querySelector('#pop-wired')?.textContent || null,
            comp: document.querySelector('#pop-comp')?.textContent || null,
            cache: document.querySelector('#pop-cache')?.textContent || null,
            webkitNote: !!(document.querySelector('#pop-webkit-note')?.textContent || '').trim()
          };
          document.querySelector('#mem-info')?.click();
          document.querySelector('#settings-btn')?.click();
          const dashboardSettingsOpen = document.querySelector('#settings-scrim')?.classList.contains('on') || false;
          document.querySelector('#settings-close')?.click();
          const dashboardSettingsClosed = !document.querySelector('#settings-scrim')?.classList.contains('on');
          return JSON.stringify({
            machine: document.querySelector('#machine')?.textContent,
            ver: document.querySelector('#ver')?.textContent,
            cpu: document.querySelector('#cpu-big')?.textContent,
            mem: document.querySelector('#mem-big')?.textContent,
            rows: document.querySelectorAll('#rows-cpu .row').length,
            live: document.querySelector('#live-text')?.textContent,
            confirmWired, drawerRows, memInfo,
            dashboardSettingsOk: dashboardSettingsOpen && dashboardSettingsClosed,
            purgeBtn: !!document.querySelector('#mem-purge')
          });
        })()
        """
        guard let w = web else {
            print("SELFTEST: web-missing")
            NSApp.terminate(nil)
            return
        }
        w.evaluateJavaScript(js) { [weak self] d, _ in
            guard let self else { return }
            let initialJson = (d as? String) ?? "{}"
            self.runSelfTestLifecycleChecks(initialJson: initialJson)
        }
    }

    private func runSelfTestLifecycleChecks(initialJson: String) {
        // 1. Settings dialog + ~/.pulse/settings.json migration & toggle round-trip (backing up live file).
        let settingsFile = settings.filePath
        let backupData = try? Data(contentsOf: URL(fileURLWithPath: settingsFile))
        let legacyPayload = "{\"statusBarGraphType\":\"bars\",\"customPreservedKey\":\"keep-me\"}\n"
        try? FileManager.default.createDirectory(atPath: pulseDir, withIntermediateDirectories: true)
        try? legacyPayload.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsFile), options: .atomic)
        settings.reload(persistMigration: true)

        openNativeSettings()
        let settingsVisible = settingsController?.window.isVisible ?? false
        settingsController?.keepMemSwitch.performClick(nil) // toggles false -> true and persists

        var settingsRoundTripOk = false
        if let savedData = try? Data(contentsOf: URL(fileURLWithPath: settingsFile)),
           let savedObj = try? JSONSerialization.jsonObject(with: savedData) as? [String: Any] {
            let verOk = (savedObj["version"] as? Int) == 1
            let migratedOk = savedObj["statusBarGraphType"] == nil
            let preservedOk = (savedObj["customPreservedKey"] as? String) == "keep-me"
            let toggledOk = (savedObj["keepDashboardInMemory"] as? Bool) == true
            settingsRoundTripOk = verOk && migratedOk && preservedOk && toggledOk
        }
        // Toggle back to false (default) so close-window check tests webview release!
        settingsController?.keepMemSwitch.performClick(nil)
        settingsController?.window.close()

        // Restore user's original settings.json before any exit.
        let restoreSettings: () -> Void = {
            if let backupData {
                try? backupData.write(to: URL(fileURLWithPath: settingsFile), options: .atomic)
            } else {
                try? FileManager.default.removeItem(atPath: settingsFile)
            }
        }

        // 2. Window close -> app stays alive, webview released, backend still alive on serverPort.
        settings.closeBehavior = "background"
        settings.keepDashboardInMemory = false
        window.close()
        let closedWindowHidden = !window.isVisible
        let closedWebReleased = (web == nil)
        guard let port = serverPort else {
            restoreSettings()
            print("SELFTEST: missing-port")
            NSApp.terminate(nil)
            return
        }

        checkServerAlive(port: port, timeout: 1.5) { [weak self] backendAliveWhileClosed in
            guard let self else { restoreSettings(); return }
            // 3. Re-open window -> fresh webview loads and renders real data.
            let reopenStart = Date()
            self.openApp()
            self.pollReopenRender(reopenStart: reopenStart, attemptsLeft: 30) { reopenOk, reopenMs in
                // 4. LaunchAgent install/remove round-trip (uses isolated label local.pulse.monitor.selftest).
                var daemonRoundTripOk = false
                if let node = findNodeFast() {
                    let mgr = LaunchAgentManager.shared
                    if case .success = mgr.installAndBootstrap(nodePath: node) {
                        let installedOk = mgr.plistExists && mgr.isLoaded()
                        _ = mgr.uninstall()
                        let removedOk = !mgr.plistExists && !mgr.isLoaded()
                        daemonRoundTripOk = installedOk && removedOk
                    }
                }
                let traceText = (try? String(contentsOfFile: BootTracer.shared.logPath, encoding: .utf8)) ?? ""
                let traceOk = traceText.contains("stage=app_launch") &&
                              traceText.contains("stage=first_render") &&
                              traceText.contains("stage=window_reopen")
                try? FileManager.default.removeItem(atPath: BootTracer.shared.logPath)
                try? FileManager.default.removeItem(atPath: pulseDir + "/daemon-selftest.log")

                restoreSettings()
                var merged = (try? JSONSerialization.jsonObject(with: Data(initialJson.utf8)) as? [String: Any]) ?? [:]
                merged["lifecycle"] = [
                    "settingsVisible": settingsVisible,
                    "settingsRoundTripOk": settingsRoundTripOk,
                    "closedWindowHidden": closedWindowHidden,
                    "closedWebReleased": closedWebReleased,
                    "backendAliveWhileClosed": backendAliveWhileClosed,
                    "reopenRenderOk": reopenOk,
                    "reopenMs": reopenMs,
                    "daemonRoundTripOk": daemonRoundTripOk,
                    "bootTraceOk": traceOk,
                ]
                let outData = (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])) ?? Data()
                let outStr = String(data: outData, encoding: .utf8) ?? initialJson
                let statusOk = self.status?.samples ?? 0
                print("SELFTEST: " + outStr +
                      " port=" + String(self.serverPort ?? -1) +
                      " statusItemSamples=" + String(statusOk) +
                      " statusItemImage=" + ((self.status?.item.button?.image != nil) ? "ok" : "missing"))
                NSApp.terminate(nil)
            }
        }
    }

    private func pollReopenRender(reopenStart: Date, attemptsLeft: Int, completion: @escaping (Bool, Int) -> Void) {
        let checkJs = """
        JSON.stringify({
          rows: document.querySelectorAll('#rows-cpu .row').length,
          live: document.querySelector('#live-text')?.textContent || '',
          cpu: document.querySelector('#cpu-big')?.textContent || '—'
        })
        """
        web?.evaluateJavaScript(checkJs) { [weak self] res, _ in
            if let s = res as? String,
               let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
               let rows = obj["rows"] as? Int, rows > 0,
               (obj["live"] as? String) == "live",
               let cpu = obj["cpu"] as? String, cpu != "—" {
                let ms = Int((Date().timeIntervalSince(reopenStart) * 1000.0).rounded())
                completion(true, ms)
                return
            }
            if attemptsLeft > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    self?.pollReopenRender(reopenStart: reopenStart, attemptsLeft: attemptsLeft - 1, completion: completion)
                }
            } else {
                let ms = Int((Date().timeIntervalSince(reopenStart) * 1000.0).rounded())
                completion(false, ms)
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
        pushSettingsToWeb()
        if ProcessInfo.processInfo.environment["PULSE_AUTOCONFIRM"] == "1" {
            web?.evaluateJavaScript("window.__autoconfirm = true") { _, _ in }
        }
    }

    // MARK: WKUIDelegate — native dialogs for confirm()/alert()/prompt()
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
            DispatchQueue.main.async { completionHandler(true) }
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
        // Kill any backend spawned directly by this app process (a LaunchAgent daemon is left running unless quitAndStopBackground was chosen).
        if spawnedNode, let p = nodeProc, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            while p.isRunning { usleep(50_000) }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        settings.shouldQuitOnClose
    }
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
