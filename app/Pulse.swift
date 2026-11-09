import Cocoa
import WebKit
import Sparkle

// Pulse — native shell for the local resource dashboard.
// - single instance: a second launch focuses/reopens the first and exits
// - reuses a running backend (LaunchAgent or prior session) via ~/.pulse/port,
//   else spawns one on a dynamic port
// - window close keeps Pulse running in the menu bar by default (configurable in Settings),
//   releasing the WKWebView by default so WebKit XPC processes exit while closed
// - live menu-bar status item with CPU + memory bars, Settings, and Quit
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
    static let currentVersion = 2
    /// Canonical order of the status-menu rows; a subset of `menuRows` = hidden.
    /// Thermal is deliberately NOT a configurable row: it is pinned directly
    /// below CPU in the menu and shares CPU's visibility.
    static let allMenuRows = ["cpu", "gpu", "memory", "network", "uptime"]
    static let defaultMenuRows = ["cpu", "gpu", "memory", "network", "uptime"]
    /// Status-bar button ids — only the continuously-valued stats have capsules
    /// (uptime is a counter, and thermal has no bar, so neither gets a capsule).
    static let allBarRows = ["cpu", "gpu", "memory", "network"]
    static let defaultBarRows = ["cpu", "gpu", "memory", "network"]
    let filePath: String
    var startAtLogin: Bool = false
    var closeBehavior: String = "background" // "background" | "quit"
    var keepDashboardInMemory: Bool = false
    var menuRows: [String] = PulseSettings.defaultMenuRows
    var barRows: [String] = PulseSettings.defaultBarRows
    var layoutGen: Int = 0 // settings-file revision (bumped on each layout write)
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
            layoutGen = obj["layoutGen"] as? Int ?? 0
            if let mr = obj["menuRows"] as? [String] {
                var v: [String] = []
                for id in mr where Self.allMenuRows.contains(id) && !v.contains(id) { v.append(id) }
                menuRows = v  // may be empty — "all hidden" is a valid layout
            } else {
                menuRows = Self.defaultMenuRows
            }
            if let br = obj["barRows"] as? [String] {
                var v: [String] = []
                for id in br where Self.allBarRows.contains(id) && !v.contains(id) { v.append(id) }
                barRows = v  // may be empty — the button falls back to a static “P”
            } else {
                barRows = menuRows.filter { Self.allBarRows.contains($0) }
            }
        } else {
            storage = [:]
            startAtLogin = false
            closeBehavior = "background"
            keepDashboardInMemory = false
            menuRows = Self.defaultMenuRows
            barRows = Self.defaultBarRows
            layoutGen = 0
        }
        if needsSave && persistMigration {
            save()
        }
    }

    func save() {
        // If another writer (the web fallback POSTs straight to the file) advanced
        // the revision since we loaded, adopt its state FIRST — a full-object write
        // from a stale in-memory copy would otherwise silently revert their change.
        mergeFromDisk()
        storage.removeValue(forKey: "statusBarGraphType")
        storage["version"] = Self.currentVersion
        storage["startAtLogin"] = startAtLogin
        storage["closeBehavior"] = closeBehavior
        storage["keepDashboardInMemory"] = keepDashboardInMemory
        storage["menuRows"] = menuRows
        storage["barRows"] = barRows
        layoutGen += 1  // this write advances the revision (any field, any writer)
        storage["layoutGen"] = layoutGen
        try? FileManager.default.createDirectory(atPath: (filePath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: storage, options: [.prettyPrinted, .sortedKeys]) {
            var out = data
            out.append(0x0A)
            try? out.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        }
    }

    /// Adopt the file's state when it has been written by someone else since we
    /// last loaded (the web settings fallback POSTs directly to the file, bypassing
    /// this in-memory copy). Returns true when anything was adopted.
    @discardableResult
    func mergeFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["layoutGen"] as? Int ?? 0) > layoutGen else { return false }
        reload(persistMigration: false)
        return true
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

    /// Force-restart an already-loaded daemon (`launchctl kickstart -k`). A rebuild
    /// changes server.js / the UI, which the plist (node path + bundle version) does
    /// NOT track — a loaded daemon would otherwise keep serving stale code forever.
    @discardableResult
    func kickstart() -> Bool {
        let (code, err) = runLaunchctl(["kickstart", "-k", serviceTarget])
        if code == 0 {
            lastError = nil
            if Thread.isMainThread { cachedIsLoaded = true }
            else { DispatchQueue.main.async { self.cachedIsLoaded = true } }
            return true
        }
        lastError = err.isEmpty ? "launchctl kickstart failed" : err
        return false
    }

    /// One-shot blocking GET of the daemon's status (utility-queue only — launchctl
    /// calls block the same way). Returns the daemon's `serverMtime`, or nil if it
    /// isn't answering (dead / still binding its socket).
    func probeServerMtime(port: Int, timeout: TimeInterval = 1.0) -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/status") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: timeout)
        let sem = DispatchSemaphore(value: 0)
        var mtime: Int?
        URLSession.shared.dataTask(with: req) { d, _, _ in
            if let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                mtime = o["serverMtime"] as? Int
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return mtime
    }

    /// Stop the running daemon for this session without deleting the plist (status-menu
    /// "Quit Pulse", Sparkle relaunch) — "Start at login" is preserved.
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
 *  Menu-bar status item: live CPU / GPU / memory rows + quick actions
 * ================================================================== */

/// One stats row in the status menu, laid out like the Stats app:
/// `label` (left) … `value` (right, at the row's end) with a proportional
/// utilization bar below, evenly padded on both sides. Fixed size so the menu
/// never resizes as values tick every 2 s.
///
/// Rows stay ENABLED on purpose: AppKit dims the custom view of a disabled
/// menu item, which would grey out the values and bars. An enabled no-action
/// row just closes the menu when clicked.
final class StatRowView: NSView {
    static let rowWidth: CGFloat = 250
    static let pad: CGFloat = 8
    static let labelW: CGFloat = 92
    static let cpuColor = NSColor(srgbRed: 1.0, green: 159.0 / 255, blue: 67.0 / 255, alpha: 1)  // --cpu #ff9f43
    static let memColor = NSColor(srgbRed: 77.0 / 255, green: 159.0 / 255, blue: 1.0, alpha: 1) // --mem #4d9fff
    static let gpuColor = NSColor(srgbRed: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255, alpha: 1) // --gpu #34c759
    static let netColor = NSColor(srgbRed: 191.0 / 255, green: 90.0 / 255, blue: 242.0 / 255, alpha: 1) // --net #bf5af2

    let valueField = NSTextField(labelWithString: "—")
    let bar = StatBarView()

    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 30))
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.menuFont(ofSize: 0)
        labelField.textColor = .secondaryLabelColor
        labelField.frame = NSRect(x: Self.pad, y: 12, width: Self.labelW, height: 14)
        addSubview(labelField)
        valueField.font = NSFont.menuFont(ofSize: 0)
        valueField.alignment = .right
        valueField.frame = NSRect(x: Self.pad + Self.labelW, y: 12, width: Self.rowWidth - 2 * Self.pad - Self.labelW, height: 14)
        valueField.lineBreakMode = .byTruncatingHead // keep the tail (units / GB) visible
        addSubview(valueField)
        bar.frame = NSRect(x: Self.pad, y: 4, width: Self.rowWidth - 2 * Self.pad, height: 4)
        addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(value: String, frac: Double?, color: NSColor) {
        if valueField.stringValue != value { valueField.stringValue = value }
        if valueField.textColor != color { valueField.textColor = color }
        // A nil frac means "no bar" (thermal): hide the track as well as the fill.
        bar.isHidden = frac == nil
        if let frac { bar.frac = frac }
        bar.barColor = color
    }
}

/// Plain `label … value` row (Uptime) — no bar, value at the end.
final class InfoRowView: NSView {
    static let rowWidth = StatRowView.rowWidth
    let valueField = NSTextField(labelWithString: "—")

    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 22))
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.menuFont(ofSize: 0)
        labelField.textColor = .secondaryLabelColor
        labelField.frame = NSRect(x: StatRowView.pad, y: 4, width: StatRowView.labelW, height: 14)
        addSubview(labelField)
        valueField.font = NSFont.menuFont(ofSize: 0)
        valueField.alignment = .right
        valueField.frame = NSRect(x: StatRowView.pad + StatRowView.labelW, y: 4,
                                  width: Self.rowWidth - 2 * StatRowView.pad - StatRowView.labelW, height: 14)
        valueField.lineBreakMode = .byTruncatingHead
        addSubview(valueField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(value: String, color: NSColor = .labelColor) {
        if valueField.stringValue != value { valueField.stringValue = value }
        if valueField.textColor != color { valueField.textColor = color }
    }
}

/// Small rounded horizontal fill (4 pt tall) over a dim track.
final class StatBarView: NSView {
    var frac: Double = 0 {
        didSet {
            if frac != oldValue { needsDisplay = true }
        }
    }
    var barColor: NSColor = .clear {
        didSet {
            if barColor != oldValue { needsDisplay = true }
        }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let r = max(0, min(1, frac))
        guard r > 0 else { return }
        barColor.setFill()
        // Never a stub narrower than the pill radius — clamp to a minimum width.
        let w = max(bounds.height, bounds.width * CGFloat(r))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                      xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

final class StatusController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var cpuHist: [Double] = []
    var memHist: [Double] = []
    var gpuHist: [Double] = []
    var netHist: [Double] = []
    var lastNet: (down: Double, up: Double) = (0, 0)
    var lastMenuRows: [String] = PulseSettings.defaultMenuRows
    var lastBarRows: [String] = PulseSettings.defaultBarRows
    var lastBarKey = ""
    var localLayoutGen = 0 // revision of the last layout WE wrote — stale polls are skipped
    var lastRenderKey = ""
    var timer: Timer?
    var samples = 0
    var port: Int?
    var lastStatusT: Double = 0
    var pollFails = 0
    var lastPurgeId = 0  // dedupe: the `purge` flag stays in /api/status until settled
    var onStaleBackend: (() -> Void)?

    // All stat rows are display-only (Open Pulse opens the dashboard) and stay
    // enabled so AppKit doesn't dim their custom views.
    let cpuItem = NSMenuItem(title: "CPU", action: nil, keyEquivalent: "")
    let gpuItem = NSMenuItem(title: "GPU", action: nil, keyEquivalent: "")
    let memItem = NSMenuItem(title: "Memory", action: nil, keyEquivalent: "")
    let cpuRow = StatRowView(label: "CPU")
    let gpuRow = StatRowView(label: "GPU")
    let memRow = StatRowView(label: "Memory")
    let thermalItem = NSMenuItem(title: "Thermal", action: nil, keyEquivalent: "")
    let netItem = NSMenuItem(title: "Network", action: nil, keyEquivalent: "")
    let uptimeItem = NSMenuItem(title: "Uptime", action: nil, keyEquivalent: "")
    let updateItem = NSMenuItem(title: "Update…", action: nil, keyEquivalent: "")
    let thermalRow = StatRowView(label: "Thermal")  // no bar — the coloured °C number is the signal
    let netRow = StatRowView(label: "Network")
    let uptimeRow = InfoRowView(label: "Uptime")
    var statItems: [String: NSMenuItem] = [:]  // populated in init (member refs aren't allowed in initializers)
    let statSep = NSMenuItem.separator()
    var lastMenuKey = ""

    let settingsItem = NSMenuItem(title: "Settings…", action: #selector(Shell.openSettings), keyEquivalent: ",")
    let openItem = NSMenuItem(title: "Open Pulse", action: #selector(Shell.openApp), keyEquivalent: "")
    let quitItem = NSMenuItem(title: "Quit Pulse", action: #selector(Shell.quitAndStopBackground), keyEquivalent: "")

    weak var shell: Shell?

    init(shell: Shell) {
        self.shell = shell
        super.init()
        statItems = ["cpu": cpuItem, "gpu": gpuItem, "memory": memItem, "thermal": thermalItem, "network": netItem, "uptime": uptimeItem]
        menu.autoenablesItems = false
        for (it, row) in [(cpuItem, cpuRow), (gpuItem, gpuRow), (memItem, memRow),
                           (thermalItem, thermalRow), (netItem, netRow), (uptimeItem, uptimeRow)] {
            it.view = row
        }
        applyMenuLayout(menu: PulseSettings.defaultMenuRows, bar: PulseSettings.defaultBarRows)
        settingsItem.target = shell
        openItem.target = shell
        // Update row sits at the top of the actions (below the stats): a persistent, low-key
        // “vX is available” affordance while one is pending. Hidden otherwise.
        updateItem.isHidden = true
        updateItem.target = shell
        updateItem.action = #selector(Shell.checkForUpdates)
        menu.addItem(updateItem)
        menu.addItem(openItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        quitItem.target = shell
        menu.addItem(quitItem)

        // Attach the menu to the item and let the SYSTEM present it. The built-in
        // click-to-toggle (click = open, click again = close) is guaranteed by
        // AppKit and is how every other menu-bar app behaves; a custom popUp()
        // bypassed that logic and re-opened on every re-click.
        item.menu = menu
        item.button?.image = Self.render(cpu: [], mem: [], gpu: [], net: [],
                                         netText: Self.netText(down: 0, up: 0),
                                         menu: PulseSettings.defaultMenuRows,
                                         bar: PulseSettings.defaultBarRows)
    }

    /// Show/hide the status-menu update row (hidden item keeps its slot — no rebuild needed).
    func showUpdateRow(_ version: String?) {
        if let v = version { updateItem.title = "Update to v\(v)…" }
        updateItem.isHidden = version == nil
    }

    /// (Re)builds the dropdown stat block from `menu` (ordered visible ids;
    /// absent id = hidden) and the status-bar button capsules from `bar` (a set —
    /// capsules follow the menu's row order). Particles refresh only on change.
    func applyMenuLayout(menu: [String], bar: [String]) {
        let known = PulseSettings.allMenuRows
        var visible = menu.filter { known.contains($0) }
        // Thermal is pinned directly below CPU — part of the CPU block (shares its
        // visibility), never a settings toggle of its own.
        if let ci = visible.firstIndex(of: "cpu") { visible.insert("thermal", at: ci + 1) }
        if visible.joined(separator: ",") != lastMenuKey {
            lastMenuKey = visible.joined(separator: ",")
            for (_, it) in statItems {
                let i = self.menu.index(of: it)
                if i >= 0 { self.menu.removeItem(at: i) }
            }
            let si = self.menu.index(of: statSep)
            if si >= 0 { self.menu.removeItem(at: si) }
            for (i, id) in visible.enumerated() {
                self.menu.insertItem(statItems[id]!, at: i)
            }
            if !visible.isEmpty { self.menu.insertItem(statSep, at: visible.count) }
        }
        lastMenuRows = visible
        lastBarRows = bar.filter { PulseSettings.allBarRows.contains($0) }
        let barKey = lastBarRows.joined(separator: ",")
        if barKey != lastBarKey { lastBarKey = barKey }
        // One source of truth for “did the button change” (values OR layout).
        let key = Self.renderKey(cpu: cpuHist, mem: memHist, gpu: gpuHist, net: netHist,
                                 netText: netText(), menu: lastMenuRows, bar: lastBarRows)
        if key != lastRenderKey {
            lastRenderKey = key
            self.item.button?.image = Self.render(cpu: cpuHist, mem: memHist, gpu: gpuHist, net: netHist,
                                                  netText: netText(), menu: lastMenuRows, bar: lastBarRows)
        }
    }

    /// The two-line number pair for the network capsule (down over up).
    func netText() -> String { Self.netText(down: lastNet.down, up: lastNet.up) }

    /// Human rate from bytes/s — mirrors the dashboard's `fmtBytes` ladder
    /// (1024-based, B/KB/MB/GB/TB) so the menu and the app always agree, down to
    /// the byte level. A bare number has no scale; even "512 B/s" is honest.
    static func rate(_ bps: Double) -> String {
        let u = ["B", "KB", "MB", "GB", "TB"]
        var i = 0, v = bps
        while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
        let s = v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        return s + " " + u[i]
    }

    static func netText(down: Double, up: Double) -> String {
        return "\(Self.rate(down))\n\(Self.rate(up))"  // ↓ over ↑, icons drawn by the cell
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
                if let mr = obj["menuRows"] as? [String] {
                    // Skip layouts the server read from disk before our own latest
                    // write — otherwise the old capsule set blinks back on for a
                    // cycle (off → on → off) after a toggle.
                    let gen = obj["layoutGen"] as? Int ?? 0
                    if gen >= self.localLayoutGen {
                        let br = (obj["barRows"] as? [String]) ?? self.lastBarRows
                        self.applyMenuLayout(menu: mr, bar: br)
                        // If a DIFFERENT writer (the web) advanced the file, sync
                        // our in-memory settings + the Settings card to match.
                        if let sh = self.shell, sh.settings.layoutGen < gen {
                            sh.settings.mergeFromDisk()
                            sh.syncAllSettingsUI()
                        }
                    }
                }
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
                    if let g = obj["gpuPct"] as? Double { self.gpuHist.append(g) }
                    if let n = obj["net"] as? [String: Any] {
                        let d = n["down"] as? Double ?? 0, u = n["up"] as? Double ?? 0
                        self.lastNet = (d, u)
                        self.netHist.append(min(100, (d + u) / 1.25e8 * 100))  // 1 Gbps reference
                    }
                    if self.cpuHist.count > 40 { self.cpuHist.removeFirst(self.cpuHist.count - 40) }
                    if self.memHist.count > 40 { self.memHist.removeFirst(self.memHist.count - 40) }
                    if self.gpuHist.count > 40 { self.gpuHist.removeFirst(self.gpuHist.count - 40) }
                    if self.netHist.count > 40 { self.netHist.removeFirst(self.netHist.count - 40) }
                }
                let key = Self.renderKey(cpu: self.cpuHist, mem: self.memHist, gpu: self.gpuHist, net: self.netHist,
                                         netText: self.netText(), menu: self.lastMenuRows, bar: self.lastBarRows)
                if key != self.lastRenderKey {
                    self.lastRenderKey = key
                    self.item.button?.image = Self.render(cpu: self.cpuHist, mem: self.memHist, gpu: self.gpuHist, net: self.netHist,
                                                          netText: self.netText(), menu: self.lastMenuRows, bar: self.lastBarRows)
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
        let gb: (Double) -> String = { let g = $0 / 1_073_741_824; return g >= 10 ? String(format: "%.0f GB", g) : String(format: "%.1f GB", g) }
        if let c = o["cpu"] as? [String: Any], let t = c["total"] as? Double {
            cpuItem.title = String(format: "CPU %.1f%%", t)
            cpuRow.set(value: String(format: "%.1f%%", t), frac: t / 100, color: StatRowView.cpuColor)
        }
        if let p = o["gpuPct"] as? Double {
            gpuItem.title = String(format: "GPU %.0f%%", p)
            gpuRow.set(value: String(format: "%.0f%%", p), frac: p / 100, color: StatRowView.gpuColor)
        } else {
            // Non-Apple-Silicon machine: keep the row, show nothing.
            gpuRow.set(value: "—", frac: 0, color: .clear)
        }
        if let p = o["memPct"] as? Double, let u = o["memUsed"] as? Double, let tt = o["memTotal"] as? Double, tt > 0 {
            let v = "\(gb(u)) / \(gb(tt)) · \(Int(p.rounded()))%"
            memItem.title = "Memory " + v
            memRow.set(value: v, frac: p / 100, color: StatRowView.memColor)
        }
        if let th = o["thermal"] as? [String: Any] {
            let lvl = th["level"] as? Int ?? 0
            let state = (th["state"] as? String) ?? "nominal"
            let pretty = String(state.prefix(1)).uppercased() + String(state.dropFirst())
            let cpuTemp = th["cpu"] as? Double
            let valStr: String
            if let t = cpuTemp {
                valStr = lvl > 0 ? "\(Int(t.rounded()))°C · \(pretty)" : "\(Int(t.rounded()))°C"
            } else {
                valStr = pretty
            }
            thermalItem.title = "Thermal \(valStr)"
            // Colour the reading on the machine's own observed range (coldest →
            // hottest since the sampler started). The span is floored at 10°C so
            // a quiet machine's few-degree range doesn't map a 1° swing onto the
            // whole green→red ramp, and the colour uses the ROUNDED value so it
            // always matches the number the user reads (and the dashboard's).
            // No bar — the number is the signal.
            let color: NSColor
            if let tRaw = cpuTemp, let lo = th["min"] as? Double, let hi = th["max"] as? Double, hi - lo >= 1 {
                let span = max(hi - lo, 10.0)
                let rangeLo = lo - (span - (hi - lo)) / 2  // widen around the observed range
                let frac = min(1, max(0, (Double(Int(tRaw.rounded())) - rangeLo) / span))
                color = NSColor(hue: 1 - frac, saturation: 0.65, brightness: 0.85, alpha: 1)
            } else {
                color = lvl == 0 ? .labelColor : (lvl == 1 ? NSColor.systemOrange : NSColor.systemRed)
            }
            thermalRow.set(value: valStr, frac: nil, color: color)
        }
        if let n = o["net"] as? [String: Any] {
            let d = n["down"] as? Double ?? 0, u = n["up"] as? Double ?? 0
            // Dominant direction; the unit travels with the figure (B/KB/MB/GB,
            // same ladder as the dashboard card, so the two surfaces agree).
            netRow.set(value: d >= u ? "↓ \(Self.rate(d))/s" : "↑ \(Self.rate(u))/s",
                       frac: min(1, (d + u) / 1.25e8), color: StatRowView.netColor)  // 1 Gbps reference
        }
        if let bt = o["bootTime"] as? Int, bt > 0 {
            let up = max(0, Int(Date().timeIntervalSince1970) - bt)
            let d = up / 86_400, h = (up % 86_400) / 3_600, m = (up % 3_600) / 60
            uptimeRow.set(value: d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m")
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

    /// Status-bar button: one capsule per stat visible in BOTH the menu and the
    /// bar set, in the menu's row order. With nothing visible, fall back to a
    /// static “P” so the item stays findable. (Thermal / uptime have no capsule;)
    /// network shows its ↓/↑ numbers instead of a bar.)
    struct Metric { let label: String; let value: Double?; let color: NSColor; var text: String? = nil }

    static func renderKey(cpu: [Double], mem: [Double], gpu: [Double], net: [Double],
                          netText: String, menu: [String], bar: [String]) -> String {
        let b: (Double?) -> Int = { Int(((min(max($0 ?? 0, 0), 100) / 100.0) * 36.0).rounded()) }
        // The net numbers only matter while the NET capsule is actually visible.
        let netPart = bar.contains("network") ? netText : ""
        return "\(b(cpu.last)):\(b(mem.last)):\(b(gpu.last)):\(netPart):\(menu.joined(separator: ","))|\(bar.joined(separator: ","))"
    }

    static func render(cpu: [Double], mem: [Double], gpu: [Double], net: [Double],
                       netText: String, menu: [String], bar: [String]) -> NSImage {
        let all: [String: Metric] = [
            "cpu": Metric(label: "CPU", value: cpu.last, color: NSColor(red: 1.0, green: 0.62, blue: 0.26, alpha: 1)),
            "gpu": Metric(label: "GPU", value: gpu.last, color: NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
            "memory": Metric(label: "MEM", value: mem.last, color: NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1)),
            "network": Metric(label: "NET", value: net.last, color: NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1), text: netText),
        ]
        let vis = menu.compactMap { id -> Metric? in guard bar.contains(id) else { return nil }; return all[id] }
        return renderBars(vis)
    }

    static func renderBars(_ metrics: [Metric]) -> NSImage {
        let barCell: CGFloat = 28, textCell: CGFloat = 58  // sized for "1023 KB" beside its arrow
        let w: CGFloat = metrics.isEmpty ? 22 : 8 + metrics.reduce(0) { $0 + ($1.text == nil ? barCell : textCell) }
        let h: CGFloat = 22
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
        let white = NSColor.white.withAlphaComponent(0.9)
        if metrics.isEmpty {
            // No stats visible — static monogram keeps the item findable.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: white,
            ]
            let s = "P" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: (w - sz.width) / 2, y: (h - sz.height) / 2), withAttributes: attrs)
            return img
        }
        let barW: CGFloat = 9, barH: CGFloat = 18
        let barY: CGFloat = (h - barH) / 2
        let cellW: CGFloat = 7
        let letterAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 6.5, weight: .semibold),
            .foregroundColor: white,
        ]
        func metric(_ x: CGFloat, _ m: Metric) {
            let cw = m.text == nil ? barCell : textCell
            let lineH = barH / CGFloat(max(1, m.label.count))
            for (j, ch) in m.label.enumerated() {
                let s = String(ch) as NSString
                let sz = s.size(withAttributes: letterAttrs)
                let cellY = barY + barH - lineH * CGFloat(j + 1)
                s.draw(
                    at: NSPoint(x: x + (cellW - sz.width) / 2,
                                y: cellY + (lineH - sz.height) / 2),
                    withAttributes: letterAttrs)
            }
            let bx = x + 8
            if let t = m.text {
                // Fixed geometry so changing digit counts don't jitter: the arrow
                // sits in a pinned left column, the figure is right-aligned to a
                // fixed edge — only the figure's left edge moves as it grows.
                let numAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.95),
                ]
                let bw = cw - 8 - 2
                let left = bx + 2
                let right = bx + bw - 2
                let iconSize: CGFloat = 7
                let lines = t.components(separatedBy: "\n")
                for (j, line) in lines.enumerated() {
                    let ns = line as NSString
                    let nsz = ns.size(withAttributes: numAttrs)
                    let lineH = barH / 2
                    let gy = barY + barH - lineH * CGFloat(j + 1)
                    if let icon = Self.tintedSymbol(j == 0 ? "arrow.down" : "arrow.up", size: iconSize, color: m.color) {
                        icon.draw(in: NSRect(x: left, y: gy + (lineH - icon.size.height) / 2,
                                             width: icon.size.width, height: icon.size.height))
                    }
                    // Right-align; clamp if the figure is wider than the space left of the edge.
                    let avail = max(0, right - (left + iconSize + 2))
                    let w = min(nsz.width, avail)
                    ns.draw(at: NSPoint(x: right - w, y: gy + (lineH - nsz.height) / 2),
                            withAttributes: numAttrs)
                }
            } else {
                let cr: CGFloat = 2
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
                ctx.setLineWidth(1)
                NSBezierPath(roundedRect: NSRect(x: bx, y: barY, width: barW, height: barH),
                             xRadius: cr, yRadius: cr).stroke()
                if let v = m.value, v > 0 {
                    let fh = CGFloat(min(v, 100) / 100) * barH
                    if fh > 0 {
                        let fr = min(cr, fh / 2, barW / 2)
                        let fill = NSBezierPath(roundedRect: NSRect(x: bx, y: barY, width: barW, height: fh),
                                                 xRadius: fr, yRadius: fr)
                        ctx.setFillColor(m.color.cgColor)
                        fill.fill()
                    }
                }
            }
        }
        var x: CGFloat = 4
        for m in metrics {
            metric(x, m)
            x += m.text == nil ? barCell : textCell
        }
        return img
    }

    private static var symbolCache: [String: NSImage] = [:]

    /// A template SF Symbol tinted with `color`, for the menu-bar bitmap (cached).
    static func tintedSymbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name):\(size):\(color.description)"
        if let cached = symbolCache[key] { return cached }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let sym = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .bold)) else { return nil }
        let img = NSImage(size: sym.size)
        img.lockFocus()
        color.set()
        let r = NSRect(origin: .zero, size: sym.size)
        sym.draw(in: r)
        r.fill(using: .sourceAtop)
        img.unlockFocus()
        symbolCache[key] = img
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
    private var menuRowSwitches: [String: NSSwitch] = [:]
    private var menuRowBarSwitches: [String: NSSwitch] = [:]
    private var menuRowBarWords: [String: NSTextField] = [:]
    private let updateStatusLabel = NSTextField(labelWithString: "Up to date")
    private let updateCheckButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
    private var menuRowLabels: [String: NSTextField] = [:]
    private var menuRowFull: [String] = PulseSettings.allMenuRows // all rows, UI order (hidden included)
    private var menuRowHidden = Set(PulseSettings.allMenuRows).subtracting(PulseSettings.defaultMenuRows)
    private var menuRowBarOn = Set(PulseSettings.defaultBarRows)

    private let panelBg = NSColor(red: 0.071, green: 0.082, blue: 0.114, alpha: 1)  // #12151d
    private let cardBg = NSColor(red: 0.090, green: 0.106, blue: 0.145, alpha: 1)   // #171b25
    private let borderCol = NSColor(red: 0.137, green: 0.165, blue: 0.220, alpha: 1) // #232a38
    private let textCol = NSColor(red: 0.910, green: 0.925, blue: 0.957, alpha: 1)   // #e8ecf4
    private let dimCol = NSColor(red: 0.545, green: 0.580, blue: 0.655, alpha: 1)    // #8b94a7
    private let accentGreen = NSColor(red: 0.176, green: 0.831, blue: 0.655, alpha: 1) // #2dd4a7
    private let accentOrange = NSColor(red: 1.0, green: 0.624, blue: 0.263, alpha: 1)  // #ff9f43

    init(shell: Shell) {
        self.shell = shell
        updateCheckButton.target = shell
        updateCheckButton.action = #selector(Shell.checkForUpdates)
        let rect = NSRect(x: 0, y: 0, width: 468, height: 660)
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

        // 4. Status menu rows card — [switch] name … [↑][↓]
        let s4Col = NSStackView()
        s4Col.orientation = .vertical
        s4Col.alignment = .leading
        s4Col.spacing = 6
        s4Col.addArrangedSubview(makeTitle("Status bar & menu"))
        s4Col.addArrangedSubview(makeNote("Which stats appear in the dropdown and in the button capsule. Thermal always shows with CPU; capsules follow the menu's row order, uptime is menu-only."))
        let rowsBox = NSStackView()
        rowsBox.orientation = .vertical
        rowsBox.alignment = .leading
        rowsBox.spacing = 5
        let rowLabels: [String: String] = ["cpu": "CPU", "gpu": "GPU", "memory": "Memory", "network": "Network", "uptime": "Uptime"]
        for (si, id) in PulseSettings.allMenuRows.enumerated() {
            let barCapable = PulseSettings.allBarRows.contains(id)
            let sw = NSSwitch()
            sw.target = self
            sw.action = #selector(onMenuRowSwitch)
            let bsw = NSSwitch()
            bsw.target = self
            bsw.action = #selector(onMenuRowBarSwitch)
            bsw.isEnabled = barCapable
            for s in [sw, bsw] {
                s.translatesAutoresizingMaskIntoConstraints = false
                s.widthAnchor.constraint(equalToConstant: 38).isActive = true
                s.heightAnchor.constraint(equalToConstant: 22).isActive = true
            }
            // Each switch carries its own word — no unlabeled adjacent toggles.
            let mkWord = { (t: String) -> NSTextField in
                let w = NSTextField(labelWithString: t)
                w.font = .systemFont(ofSize: 11)
                w.textColor = self.dimCol
                w.translatesAutoresizingMaskIntoConstraints = false
                w.widthAnchor.constraint(equalToConstant: 28).isActive = true
                return w
            }
            let lbl = NSTextField(labelWithString: rowLabels[id] ?? id)
            lbl.font = .systemFont(ofSize: 12)
            lbl.textColor = textCol
            let up = NSButton(title: "", target: self, action: #selector(onMenuRowUp))
            let dn = NSButton(title: "", target: self, action: #selector(onMenuRowDown))
            up.tag = si
            dn.tag = si
            up.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up")
            dn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down")
            for b in [up, dn] {
                b.imagePosition = .imageOnly
                b.isBordered = false
                b.bezelStyle = .regularSquare
                b.contentTintColor = dimCol
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 22).isActive = true
                b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            }
            let wordM = mkWord("Menu")
            let wordB = mkWord("Bar")
            let row = NSStackView(views: [lbl, sw, wordM, bsw, wordB, up, dn])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = 8
            for v in [sw, bsw, up, dn] {
                v.setContentHuggingPriority(.required, for: .horizontal)
                v.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            // The name takes the slack so the labeled controls stay right-aligned.
            lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
            lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            menuRowSwitches[id] = sw
            menuRowBarSwitches[id] = bsw
            menuRowBarWords[id] = wordB
            menuRowLabels[id] = lbl
            rowsBox.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsBox.widthAnchor).isActive = true
        }
        s4Col.addArrangedSubview(rowsBox)
        let card4 = makeCard(s4Col)

        // 5. Updates card — status + an explicit “Check for Updates…” affordance.
        let s5Left = NSStackView()
        s5Left.orientation = .vertical
        s5Left.alignment = .leading
        s5Left.spacing = 3
        let s5Header = NSStackView()
        s5Header.orientation = .horizontal
        s5Header.alignment = .centerY
        s5Header.spacing = 8
        updateStatusLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        updateStatusLabel.textColor = dimCol
        s5Header.addArrangedSubview(makeTitle("Updates"))
        s5Header.addArrangedSubview(updateStatusLabel)
        s5Left.addArrangedSubview(s5Header)
        s5Left.addArrangedSubview(makeNote("Checks at launch. A declined update is offered again on next launch, and stays marked (thin green strip, menu row) until installed."))
        let s5Row = NSStackView(views: [s5Left, updateCheckButton])
        s5Row.orientation = .horizontal
        s5Row.alignment = .top
        s5Row.distribution = .fill
        s5Row.spacing = 14
        updateCheckButton.setContentHuggingPriority(.required, for: .horizontal)
        let card5 = makeCard(s5Row)

        for card in [card1, card2, card3, card4, card5] {
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
        let vis = shell.settings.menuRows
        let known = PulseSettings.allMenuRows
        let prevHidden = menuRowFull.filter { menuRowHidden.contains($0) && !vis.contains($0) }
        let hidden = prevHidden + known.filter { !vis.contains($0) && !prevHidden.contains($0) }
        menuRowHidden = Set(hidden)
        // Keep each row's slot stable: only adopt the incoming order when the
        // visible projection actually differs (external change / first open).
        let projected = menuRowFull.filter { !menuRowHidden.contains($0) }
        if projected != vis {
            menuRowFull = vis + hidden
        }
        let bar = shell.settings.barRows
        if Set(bar) != menuRowBarOn { menuRowBarOn = Set(bar) }
        if let ver = shell.pendingUpdateVersion {
            updateStatusLabel.stringValue = "v\(ver) available"
            updateStatusLabel.textColor = accentGreen
        } else {
            updateStatusLabel.stringValue = "Up to date"
            updateStatusLabel.textColor = dimCol
        }
        rebuildMenuRowsUI()
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

    @objc private func onMenuRowSwitch(_ sender: NSControl) {
        for (id, sw) in menuRowSwitches where sw === sender {
            if menuRowHidden.contains(id) { menuRowHidden.remove(id) } else { menuRowHidden.insert(id) }
        }
        rebuildMenuRowsUI()
        pushMenuRows()
    }

    @objc private func onMenuRowBarSwitch(_ sender: NSControl) {
        for (id, sw) in menuRowBarSwitches where sw === sender {
            if menuRowBarOn.contains(id) { menuRowBarOn.remove(id) } else { menuRowBarOn.insert(id) }
        }
        rebuildMenuRowsUI()
        pushMenuRows()
    }

    @objc private func onMenuRowUp(_ sender: NSControl) { moveMenuRow((sender as? NSButton)?.tag, -1) }

    @objc private func onMenuRowDown(_ sender: NSControl) { moveMenuRow((sender as? NSButton)?.tag, 1) }

    private func moveMenuRow(_ si: Int?, _ dir: Int) {
        guard let si, PulseSettings.allMenuRows.indices.contains(si) else { return }
        let id = PulseSettings.allMenuRows[si]
        guard let i = menuRowFull.firstIndex(of: id) else { return }
        let j = i + dir
        guard menuRowFull.indices.contains(j) else { return }
        menuRowFull.swapAt(i, j)
        rebuildMenuRowsUI()
        pushMenuRows()
    }

    private func rebuildMenuRowsUI() {
        for (id, sw) in menuRowSwitches {
            sw.state = menuRowHidden.contains(id) ? .off : .on
            menuRowLabels[id]?.textColor = menuRowHidden.contains(id) ? dimCol : textCol
        }
        for (id, sw) in menuRowBarSwitches {
            sw.state = menuRowBarOn.contains(id) ? .on : .off
            sw.isEnabled = PulseSettings.allBarRows.contains(id)
            menuRowBarWords[id]?.alphaValue = PulseSettings.allBarRows.contains(id) ? 1 : 0.4
        }
    }

    private func pushMenuRows() {
        shell?.setMenuLayout(
            menu: menuRowFull.filter { !menuRowHidden.contains($0) },
            bar: PulseSettings.allBarRows.filter { menuRowBarOn.contains($0) })
    }
}

/* ================================================================== *
 *  App shell
 * ================================================================== */
/// Clickable view — the update strip's 4px edge needs a pointer cursor + a click target.
final class ClickableView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

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
    var pendingUpdateVersion: String?   // newest appcast version not yet installed
    let updateStrip = ClickableView()
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
        syncUpdateStrip()
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
        syncUpdateStrip()
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
            "menuRows": settings.menuRows,
            "barRows": settings.barRows,
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
        settingsController?.syncFromState()
        pushSettingsToWeb()
    }

    func setCloseBehavior(_ mode: String) {
        settings.mergeFromDisk()
        settings.closeBehavior = (mode == "quit") ? "quit" : "background"
        settings.save()
        syncAllSettingsUI()
    }

    func setKeepDashboardInMemory(_ keep: Bool) {
        settings.mergeFromDisk()
        settings.keepDashboardInMemory = keep
        settings.save()
        if !keep && !window.isVisible {
            releaseWebView()
        }
        syncAllSettingsUI()
    }

    func setMenuLayout(menu: [String], bar: [String]) {
        settings.mergeFromDisk()
        var mv: [String] = []
        for id in menu where PulseSettings.allMenuRows.contains(id) && !mv.contains(id) { mv.append(id) }
        settings.menuRows = mv  // may be empty — "all hidden" is a valid layout
        var bv: [String] = []
        for id in bar where PulseSettings.allBarRows.contains(id) && !bv.contains(id) { bv.append(id) }
        settings.barRows = bv  // may be empty — the button shows the static “P”
        settings.save()  // save() advances layoutGen
        status?.localLayoutGen = settings.layoutGen
        // Switch state first, capsule second — the assigned state settles before
        // the button visibly changes.
        syncAllSettingsUI()
        status?.applyMenuLayout(menu: settings.menuRows, bar: settings.barRows)
    }

    func setStartAtLogin(_ enabled: Bool) {
        let mgr = LaunchAgentManager.shared
        mgr.lastError = nil
        mgr.isTransitioning = true
        switchingBackend = true
        settings.mergeFromDisk()
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
                    // If we spawned our own backend while waiting for the daemon, release it
                    // before adopting — the port file can point at only one backend. (The
                    // dying backend only removes the port file if it still owns it, so the
                    // daemon's entry survives.)
                    if self.spawnedNode, self.serverPort != p, let dying = self.nodeProc {
                        self.nodeProc = nil
                        self.spawnedNode = false
                        if dying.isRunning { dying.terminate() }
                    }
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

    /// The status menu's single Quit: stops the background sampler (LaunchAgent
    /// daemon) for this session, then terminates. App-spawned backends are
    /// cleaned up in applicationShouldTerminate; the plist (Start at login) stays.
    @objc func quitAndStopBackground() {
        quitting = true
        _ = LaunchAgentManager.shared.bootoutSessionOnly()
        NSApp.terminate(nil)
    }

    @objc func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    /// Re-parent the strip onto whatever the current content view is — the content view
    /// is replaced when the web opens/closes/reopens.
    func syncUpdateStrip() {
        guard let cv = window.contentView else { return }
        updateStrip.frame = NSRect(x: 0, y: cv.frame.maxY - 4, width: cv.frame.width, height: 4)
        cv.addSubview(updateStrip)
    }

    /// Reflect the update state on every surface: the thin top strip, the status-menu row,
    /// the native Settings card, and the dashboard.
    func setUpdateIndicators() {
        let v = pendingUpdateVersion
        updateStrip.isHidden = v == nil
        updateStrip.toolTip = v.map { "Pulse \($0) is available — click to update" }
        syncUpdateStrip()
        status?.showUpdateRow(v)
        settingsController?.syncFromState()
        pushUpdateToWeb()
    }

    func pushUpdateToWeb() {
        guard let w = web, loaded else { return }
        let payload: [String: Any] = ["available": pendingUpdateVersion ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        w.evaluateJavaScript("window.__pulseUpdate && window.__pulseUpdate(\(json))", completionHandler: nil)
    }

    // MARK: Sparkle delegate — restart LaunchAgent on auto-update so it never serves an old bundle
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        quitting = true
        if LaunchAgentManager.shared.cachedIsLoaded || LaunchAgentManager.shared.plistExists {
            _ = LaunchAgentManager.shared.bootoutSessionOnly()
        }
    }

    // Update availability. Declining dismisses the sheet for now — Sparkle re-offers on the
    // next launch — and the quiet strip/menu row remain as a persistent signal until the
    // installed version actually changes.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingUpdateVersion = item.displayVersionString
        setUpdateIndicators()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        pendingUpdateVersion = nil
        setUpdateIndicators()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // A failed check is not “up to date” — keep the previous state.
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .install { pendingUpdateVersion = nil }  // installing → relaunch; the new build re-checks
        // Dismiss / Skip: keep the indicators — a quiet “install it any time” signal.
        setUpdateIndicators()
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
            case "setMenuRows":
                if let val = body["rows"] as? [String] { setMenuLayout(menu: val, bar: body["bar"] as? [String] ?? settings.barRows) }
            case "checkForUpdates":
                checkForUpdates()
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

        // Very thin strip along the top edge — the quiet, persistent “an update is
        // available, click to install” indicator (hidden until one is).
        updateStrip.wantsLayer = true
        updateStrip.layer?.backgroundColor = NSColor(red: 0.17, green: 0.83, blue: 0.65, alpha: 1).cgColor  // --net
        updateStrip.isHidden = true
        updateStrip.autoresizingMask = [.width, .minYMargin]
        updateStrip.onClick = { [weak self] in self?.checkForUpdates() }

        // Kick off backend discovery / spawn immediately so it runs in parallel with
        // WKWebView, menu bar, and Sparkle initialization on the main thread.
        status = StatusController(shell: self)
        status?.localLayoutGen = settings.layoutGen
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
                    // Daemon is loaded with the current plist — but a rebuild changes the
                    // CODE (server.js), which the plist doesn't track. Probe the daemon's
                    // serverMtime and kickstart it if stale, so we adopt ONE fresh backend
                    // instead of spawning a second one beside a stale daemon.
                    var kicked = false
                    if let p = readPortFile(), let disk = expectedServerMtime(),
                       let sm = agent.probeServerMtime(port: p), sm != disk {
                        kicked = agent.kickstart()
                    }
                    DispatchQueue.main.async {
                        // Give the (re)started daemon a moment to bind and serve fresh data
                        // (e.g. still finishing its first sample right after boot).
                        self?.attachToDaemonPort(attemptsLeft: kicked ? 25 : 20)
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
            let verOk = (savedObj["version"] as? Int) == PulseSettings.currentVersion
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
