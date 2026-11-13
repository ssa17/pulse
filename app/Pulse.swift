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

struct PortFileInfo {
    let port: Int
    let pid: Int32?
}

func portFilePath() -> String {
    pulseDir + (isSelfTest ? "/port-selftest" : "/port")
}

func readPortFileInfo(path: String = portFilePath()) -> PortFileInfo? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let lines = s.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard let first = lines.first, let port = Int(first), port > 0 && port < 65536 else { return nil }
    let pid: Int32? = lines.count >= 2 ? Int32(lines[1]).flatMap { $0 > 0 ? $0 : nil } : nil
    return PortFileInfo(port: port, pid: pid)
}

func readPortFile() -> Int? {
    readPortFileInfo()?.port
}

func isProcessAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

/// Claims the port file for a promoted backend if no live owner currently holds it.
func writePortFileIfUnowned(port: Int, pid: Int32, path: String = portFilePath()) {
    if let existing = readPortFileInfo(path: path), let owner = existing.pid, owner != pid, isProcessAlive(owner) {
        return
    }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? "\(port)\n\(pid)\n".write(toFile: path, atomically: true, encoding: .utf8)
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
    var keepDashboardInMemory: Bool = true
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
            keepDashboardInMemory = true
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
private func devCheckoutDir() -> URL? {
    let fm = FileManager.default
    let res = Bundle.main.resourcePath ?? "."
    var url = URL(fileURLWithPath: res)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
        if fm.isReadableFile(atPath: url.appendingPathComponent("server.js").path),
           fm.isReadableFile(atPath: url.appendingPathComponent("public/index.html").path) {
            return url
        }
    }
    return nil
}

func serverScriptPath() -> String {
    if let dev = devCheckoutDir() { return dev.appendingPathComponent("server.js").path }
    return (Bundle.main.resourcePath ?? ".") + "/server.js"
}

func uiSourcePath() -> (html: String, dir: String) {
    if let dev = devCheckoutDir() {
        let dir = dev.appendingPathComponent("public").path
        return (dir + "/index.html", dir)
    }
    let dir = (Bundle.main.resourcePath ?? ".") + "/public"
    return (dir + "/index.html", dir)
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
            env["PULSE_PORT_FILE"] = portFilePath()
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

/// Centered group section header (CPU, GPU, MEMORY, SYSTEM) in the status menu,
/// with an optional padded top divider line to separate groups cleanly.
final class SectionHeaderView: NSView {
    static let rowWidth = StatRowView.rowWidth
    static let pad = StatRowView.pad
    private let labelField = NSTextField(labelWithString: "")
    private let titleText: String
    var showDivider: Bool = false {
        didSet {
            guard showDivider != oldValue else { return }
            updateLayout()
        }
    }

    init(title: String, showDivider: Bool = false) {
        self.titleText = title
        self.showDivider = showDivider
        let h: CGFloat = showDivider ? 36 : 26
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: h))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 0.28, green: 0.58, blue: 1.0, alpha: 1.0),
            .kern: 1.2,
            .paragraphStyle: style,
        ]
        labelField.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: attrs)
        labelField.alignment = .center
        labelField.isBezeled = false
        labelField.drawsBackground = false
        labelField.isEditable = false
        labelField.isSelectable = false
        addSubview(labelField)
        updateLayout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateLayout() {
        let h: CGFloat = showDivider ? 36 : 26
        frame = NSRect(x: 0, y: 0, width: Self.rowWidth, height: h)
        labelField.frame = NSRect(x: 0, y: 4, width: Self.rowWidth, height: 16)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showDivider else { return }
        NSColor.labelColor.withAlphaComponent(0.11).setFill()
        NSRect(x: Self.pad, y: bounds.height - 8, width: Self.rowWidth - 2 * Self.pad, height: 1).fill()
    }
}

/// Dual rolling wave graph (rolling 30s) with subtitle and smooth antialiased curves.
final class WaveGraphRowView: NSView {
    static let rowWidth = StatRowView.rowWidth
    static let pad = StatRowView.pad
    static let maxHistory = 30

    private let subtitleField = NSTextField(labelWithString: "")
    var series1: [Double] = [] { didSet { needsDisplay = true } }
    var series2: [Double] = [] { didSet { needsDisplay = true } }
    var color1: NSColor
    var color2: NSColor

    init(subtitle: String, color1: NSColor, color2: NSColor) {
        self.color1 = color1
        self.color2 = color2
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 52))

        subtitleField.stringValue = subtitle
        subtitleField.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.frame = NSRect(x: Self.pad, y: 33, width: Self.rowWidth - 2 * Self.pad, height: 16)
        addSubview(subtitleField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSubtitle(_ text: String) {
        if subtitleField.stringValue != text { subtitleField.stringValue = text }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let graphRect = NSRect(x: Self.pad, y: 5, width: Self.rowWidth - 2 * Self.pad, height: 25)

        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        let bgPath = NSBezierPath(roundedRect: graphRect, xRadius: 4, yRadius: 4)
        bgPath.fill()
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        bgPath.lineWidth = 0.5
        bgPath.stroke()

        // Subtle mid-line for visual scale
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSRect(x: graphRect.minX + 2, y: graphRect.midY, width: graphRect.width - 4, height: 0.5).fill()

        // Adaptive ceiling (floored at 35% so normal 5–25% core activity is clearly visible,
        // scaling up to 100% under heavy load).
        let peak = max(series1.max() ?? 0, series2.max() ?? 0)
        let scaleMax = min(100.0, max(35.0, peak * 1.25))

        NSGraphicsContext.saveGraphicsState()
        bgPath.addClip()
        drawSeries(series1, color: color1, scaleMax: scaleMax, in: graphRect)
        drawSeries(series2, color: color2, scaleMax: scaleMax, in: graphRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSeries(_ data: [Double], color: NSColor, scaleMax: Double, in rect: NSRect) {
        guard !data.isEmpty else { return }
        // If fewer than maxHistory points exist, stretch or pad from the first sample so
        // the wave spans the full graph width immediately instead of a tiny stub.
        let pts: [Double]
        if data.count < Self.maxHistory {
            pts = Array(repeating: data[0], count: Self.maxHistory - data.count) + data
        } else {
            pts = Array(data.suffix(Self.maxHistory))
        }

        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineJoinStyle = .round
        path.lineCapStyle = .round

        let n = CGFloat(Self.maxHistory - 1)
        let innerH = rect.height - 4
        for (i, val) in pts.enumerated() {
            let x = rect.minX + (CGFloat(i) / n) * rect.width
            let norm = max(0, min(1.0, val / scaleMax))
            let y = rect.minY + 2 + CGFloat(norm) * innerH
            let pt = NSPoint(x: x, y: y)
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }

        if let fillPath = path.copy() as? NSBezierPath {
            fillPath.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            fillPath.line(to: NSPoint(x: rect.minX, y: rect.minY))
            fillPath.close()
            color.withAlphaComponent(0.12).setFill()
            fillPath.fill()
        }

        color.setStroke()
        path.stroke()
    }
}

/// Multi-segmented progress bar for Memory pools.
final class SegmentedBarView: NSView {
    struct Segment {
        var frac: Double
        var color: NSColor
    }
    var segments: [Segment] = [] {
        didSet { needsDisplay = true }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        path.fill()
        guard !segments.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        var curX: CGFloat = 0
        let totalW = bounds.width
        for seg in segments {
            let segW = totalW * CGFloat(max(0, seg.frac))
            if segW > 0 {
                seg.color.setFill()
                NSRect(x: curX, y: 0, width: segW, height: bounds.height).fill()
                curX += segW
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Memory row with "Memory" on the left, "Used / Total GB · %" on the right, and a segmented bar below.
final class MemoryRowView: NSView {
    static let rowWidth = StatRowView.rowWidth
    static let pad = StatRowView.pad

    let valueField = NSTextField(labelWithString: "—")
    let bar = SegmentedBarView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 34))
        let labelField = NSTextField(labelWithString: "Memory")
        labelField.font = NSFont.menuFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        labelField.sizeToFit()
        let lw = ceil(labelField.frame.width) + 2
        labelField.frame = NSRect(x: Self.pad, y: 13, width: lw, height: 18)
        addSubview(labelField)

        let vx = Self.pad + lw + 6
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        valueField.alignment = .right
        valueField.textColor = .labelColor
        valueField.frame = NSRect(x: vx, y: 13, width: Self.rowWidth - Self.pad - vx, height: 18)
        valueField.lineBreakMode = .byTruncatingHead
        addSubview(valueField)

        bar.frame = NSRect(x: Self.pad, y: 4, width: Self.rowWidth - 2 * Self.pad, height: 4)
        addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(valueStr: String, segments: [SegmentedBarView.Segment]) {
        if valueField.stringValue != valueStr { valueField.stringValue = valueStr }
        bar.segments = segments
    }
}

/// Memory pool breakdown row with a colored swatch, label, and formatted value.
final class LegendRowView: NSView {
    static let rowWidth = StatRowView.rowWidth
    static let pad = StatRowView.pad
    private let swatch = NSView()
    private let labelField = NSTextField(labelWithString: "")
    let valueField = NSTextField(labelWithString: "—")

    init(label: String, color: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 22))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        swatch.layer?.cornerRadius = 2
        swatch.frame = NSRect(x: Self.pad, y: 7, width: 8, height: 8)
        addSubview(swatch)

        labelField.stringValue = label
        labelField.font = NSFont.menuFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        labelField.sizeToFit()
        let lw = ceil(labelField.frame.width) + 2
        labelField.frame = NSRect(x: Self.pad + 14, y: 2, width: lw, height: 18)
        addSubview(labelField)

        let vx = Self.pad + 14 + lw + 6
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        valueField.alignment = .right
        valueField.frame = NSRect(x: vx, y: 2, width: Self.rowWidth - Self.pad - vx, height: 18)
        valueField.lineBreakMode = .byTruncatingHead
        addSubview(valueField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(value: String, color: NSColor = .labelColor) {
        if valueField.stringValue != value { valueField.stringValue = value }
        if valueField.textColor != color { valueField.textColor = color }
    }
}

/// One stats row in the status menu, laid out like the Stats app:
/// `label` (left) … `value` (right, at the row's end) with a proportional
/// utilization bar below, evenly padded on both sides. Fixed size so the menu
/// never resizes as values tick every 2 s.
///
/// Rows stay ENABLED on purpose: AppKit dims the custom view of a disabled
/// menu item, which would grey out the values and bars. An enabled no-action
/// row just closes the menu when clicked.
final class StatRowView: NSView {
    static let rowWidth: CGFloat = 272
    static let pad: CGFloat = 14
    static let cpuColor = NSColor(srgbRed: 1.0, green: 159.0 / 255, blue: 67.0 / 255, alpha: 1)  // --cpu #ff9f43
    static let memColor = NSColor(srgbRed: 77.0 / 255, green: 159.0 / 255, blue: 1.0, alpha: 1) // --mem #4d9fff
    static let gpuColor = NSColor(srgbRed: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255, alpha: 1) // --gpu #34c759
    static let netColor = NSColor(srgbRed: 191.0 / 255, green: 90.0 / 255, blue: 242.0 / 255, alpha: 1) // --net #bf5af2

    let valueField = NSTextField(labelWithString: "—")
    let bar = StatBarView()

    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 34))
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.menuFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        labelField.sizeToFit()
        let lw = ceil(labelField.frame.width) + 2
        labelField.frame = NSRect(x: Self.pad, y: 13, width: lw, height: 18)
        addSubview(labelField)

        let vx = Self.pad + lw + 6
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        valueField.alignment = .right
        valueField.frame = NSRect(x: vx, y: 13, width: Self.rowWidth - Self.pad - vx, height: 18)
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

/// Plain `label … value` row (Thermal, Load avg, Uptime, Network, GPU memory) — no bar, value at the end.
final class InfoRowView: NSView {
    static let rowWidth = StatRowView.rowWidth
    let valueField = NSTextField(labelWithString: "—")

    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 24))
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.menuFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        labelField.sizeToFit()
        let lw = ceil(labelField.frame.width) + 2
        labelField.frame = NSRect(x: StatRowView.pad, y: 3, width: lw, height: 18)
        addSubview(labelField)

        let vx = StatRowView.pad + lw + 6
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        valueField.alignment = .right
        valueField.frame = NSRect(x: vx, y: 3, width: Self.rowWidth - StatRowView.pad - vx, height: 18)
        valueField.lineBreakMode = .byTruncatingHead
        addSubview(valueField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(value: String, color: NSColor = .labelColor) {
        if valueField.stringValue != value { valueField.stringValue = value }
        if valueField.textColor != color { valueField.textColor = color }
    }

    /// Attributed variant for the thermal row: the state word in `stateColor`
    /// (SMC throttle state — nominal reads neutral, so "Nominal" is never red)
    /// and the temperature in `valueColor` (its own green→red ramp), both
    /// right-aligned like plain values.
    func set(state: String, value: String, stateColor: NSColor, valueColor: NSColor) {
        let p = NSMutableParagraphStyle(); p.alignment = .right
        let attr = NSMutableAttributedString(string: state, attributes: [
            .font: valueField.font as Any,
            .foregroundColor: stateColor,
            .paragraphStyle: p,
        ])
        attr.append(NSAttributedString(string: " \u{00B7} " + value, attributes: [
            .font: valueField.font as Any,
            .foregroundColor: valueColor,
            .paragraphStyle: p,
        ]))
        valueField.attributedStringValue = attr
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

final class StatusController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var cpuHist: [Double] = []
    var memHist: [Double] = []
    var gpuHist: [Double] = []
    var netHist: [Double] = []
    var eCpuHist: [Double] = []
    var pCpuHist: [Double] = []
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

    // Memory breakdown colors
    static let wiredColor = NSColor(srgbRed: 0.24, green: 0.58, blue: 1.0, alpha: 1.0)
    static let activeColor = NSColor(srgbRed: 0.95, green: 0.32, blue: 0.35, alpha: 1.0)
    static let compColor = NSColor(srgbRed: 0.75, green: 0.25, blue: 0.95, alpha: 1.0)
    static let freeColor = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)

    // All stat rows are display-only (Open Pulse opens the dashboard) and stay
    // enabled so AppKit doesn't dim their custom views.
    let cpuItem = NSMenuItem(title: "CPU", action: nil, keyEquivalent: "")
    let gpuItem = NSMenuItem(title: "GPU", action: nil, keyEquivalent: "")
    let memItem = NSMenuItem(title: "Memory", action: nil, keyEquivalent: "")
    let cpuRow = StatRowView(label: "CPU")
    let gpuRow = StatRowView(label: "GPU")
    let memRow = MemoryRowView()

    // Dual rolling wave graph for E and P core clusters
    let cpuWaveItem = NSMenuItem(title: "CPU Cores", action: nil, keyEquivalent: "")
    let cpuWaveRow = WaveGraphRowView(
        subtitle: "E (amber) / P (blue) usage · 30s",
        color1: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.26, alpha: 1.0),
        color2: NSColor(srgbRed: 0.24, green: 0.58, blue: 1.0, alpha: 1.0)
    )

    let thermalItem = NSMenuItem(title: "Thermal", action: nil, keyEquivalent: "")
    let thermalRow = InfoRowView(label: "Thermal")
    let loadAvgItem = NSMenuItem(title: "Load avg", action: nil, keyEquivalent: "")
    let loadAvgRow = InfoRowView(label: "Load avg")
    let uptimeItem = NSMenuItem(title: "Uptime", action: nil, keyEquivalent: "")
    let uptimeRow = InfoRowView(label: "Uptime")
    let gpuMemItem = NSMenuItem(title: "GPU memory", action: nil, keyEquivalent: "")
    let gpuMemRow = InfoRowView(label: "GPU memory")
    let netItem = NSMenuItem(title: "Network", action: nil, keyEquivalent: "")
    let netRow = InfoRowView(label: "Network")

    // Memory pool rows
    let wiredItem = NSMenuItem(title: "Wired", action: nil, keyEquivalent: "")
    let wiredRow = LegendRowView(label: "Wired", color: StatusController.wiredColor)
    let activeItem = NSMenuItem(title: "Active", action: nil, keyEquivalent: "")
    let activeRow = LegendRowView(label: "Active", color: StatusController.activeColor)
    let compItem = NSMenuItem(title: "Compressed", action: nil, keyEquivalent: "")
    let compRow = LegendRowView(label: "Compressed", color: StatusController.compColor)
    let freeItem = NSMenuItem(title: "Free", action: nil, keyEquivalent: "")
    let freeRow = LegendRowView(label: "Free", color: StatusController.freeColor)
    let memPressureItem = NSMenuItem(title: "Pressure", action: nil, keyEquivalent: "")
    let memPressureRow = InfoRowView(label: "Pressure")
    let swapItem = NSMenuItem(title: "Swap", action: nil, keyEquivalent: "")
    let swapRow = InfoRowView(label: "Swap")

    let updateItem = NSMenuItem(title: "Update…", action: nil, keyEquivalent: "")

    // Centered section headers (styled like the omlx stats display)
    let cpuHeaderItem = NSMenuItem(title: "CPU", action: nil, keyEquivalent: "")
    let gpuHeaderItem = NSMenuItem(title: "GPU", action: nil, keyEquivalent: "")
    let memHeaderItem = NSMenuItem(title: "MEMORY", action: nil, keyEquivalent: "")
    let sysHeaderItem = NSMenuItem(title: "SYSTEM", action: nil, keyEquivalent: "")

    let cpuHeader = SectionHeaderView(title: "CPU")
    let gpuHeader = SectionHeaderView(title: "GPU")
    let memHeader = SectionHeaderView(title: "MEMORY")
    let sysHeader = SectionHeaderView(title: "SYSTEM")

    let statSep = NSMenuItem.separator()
    var dynamicMenuItems: [NSMenuItem] = []
    var lastMenuKey = ""

    let settingsItem = NSMenuItem(title: "Settings…", action: #selector(Shell.openSettings), keyEquivalent: ",")
    let openItem = NSMenuItem(title: "Open Pulse", action: #selector(Shell.openApp), keyEquivalent: "")
    let quitItem = NSMenuItem(title: "Quit Pulse", action: #selector(Shell.quitAndStopBackground), keyEquivalent: "")

    weak var shell: Shell?

    init(shell: Shell) {
        self.shell = shell
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for (it, row) in [
            (cpuItem, cpuRow), (cpuWaveItem, cpuWaveRow),
            (thermalItem, thermalRow), (loadAvgItem, loadAvgRow), (uptimeItem, uptimeRow),
            (gpuItem, gpuRow), (gpuMemItem, gpuMemRow),
            (memItem, memRow), (wiredItem, wiredRow), (activeItem, activeRow), (compItem, compRow), (freeItem, freeRow),
            (memPressureItem, memPressureRow), (swapItem, swapRow),
            (netItem, netRow)
        ] {
            it.view = row
        }
        cpuHeaderItem.view = cpuHeader
        gpuHeaderItem.view = gpuHeader
        memHeaderItem.view = memHeader
        sysHeaderItem.view = sysHeader

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

    func menuWillOpen(_ menu: NSMenu) {
        poll()
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

            for it in dynamicMenuItems {
                let idx = self.menu.index(of: it)
                if idx >= 0 { self.menu.removeItem(at: idx) }
            }
            dynamicMenuItems.removeAll()

            var newItems: [NSMenuItem] = []
            var addedGroups = Set<String>()

            let addSystemGroup = {
                guard !addedGroups.contains("system") else { return }
                let hasNet = menu.contains("network")
                let hasUptime = menu.contains("uptime")
                guard hasNet || hasUptime else { return }
                addedGroups.insert("system")
                self.sysHeader.showDivider = !newItems.isEmpty
                newItems.append(self.sysHeaderItem)
                newItems.append(self.loadAvgItem)
                if hasUptime { newItems.append(self.uptimeItem) }
                if hasNet { newItems.append(self.netItem) }
            }

            for id in menu where known.contains(id) {
                if id == "cpu" && !addedGroups.contains("cpu") {
                    addedGroups.insert("cpu")
                    cpuHeader.showDivider = !newItems.isEmpty
                    newItems.append(cpuHeaderItem)
                    newItems.append(cpuItem)
                    newItems.append(cpuWaveItem)
                    newItems.append(thermalItem)
                } else if id == "gpu" && !addedGroups.contains("gpu") {
                    addedGroups.insert("gpu")
                    gpuHeader.showDivider = !newItems.isEmpty
                    newItems.append(gpuHeaderItem)
                    newItems.append(gpuItem)
                    newItems.append(gpuMemItem)
                } else if id == "memory" && !addedGroups.contains("memory") {
                    addedGroups.insert("memory")
                    memHeader.showDivider = !newItems.isEmpty
                    newItems.append(memHeaderItem)
                    newItems.append(memItem)
                    newItems.append(wiredItem)
                    newItems.append(activeItem)
                    newItems.append(compItem)
                    newItems.append(freeItem)
                    newItems.append(memPressureItem)
                    newItems.append(swapItem)
                } else if id == "network" || id == "uptime" {
                    addSystemGroup()
                }
            }

            if !newItems.isEmpty {
                newItems.append(statSep)
            }

            for (i, it) in newItems.enumerated() {
                self.menu.insertItem(it, at: i)
            }
            dynamicMenuItems = newItems
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
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
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
                    if let c = obj["cpu"] as? [String: Any], let t = (c["total"] as? NSNumber)?.doubleValue {
                        self.cpuHist.append(t)
                        if let e = (c["eCores"] as? NSNumber)?.doubleValue {
                            self.eCpuHist.append(e)
                            if self.eCpuHist.count > WaveGraphRowView.maxHistory { self.eCpuHist.removeFirst(self.eCpuHist.count - WaveGraphRowView.maxHistory) }
                        }
                        if let p = (c["pCores"] as? NSNumber)?.doubleValue {
                            self.pCpuHist.append(p)
                            if self.pCpuHist.count > WaveGraphRowView.maxHistory { self.pCpuHist.removeFirst(self.pCpuHist.count - WaveGraphRowView.maxHistory) }
                        }
                    }
                    if let m = (obj["memPct"] as? NSNumber)?.doubleValue { self.memHist.append(m) }
                    if let g = (obj["gpuPct"] as? NSNumber)?.doubleValue { self.gpuHist.append(g) }
                    if let n = obj["net"] as? [String: Any] {
                        let d = (n["down"] as? NSNumber)?.doubleValue ?? 0
                        let u = (n["up"] as? NSNumber)?.doubleValue ?? 0
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
        let fmtMem: (Double) -> String = { b in
            let gb = b / 1_073_741_824
            if gb >= 1 { return String(format: "%.2f GB", gb) }
            let mb = b / 1_048_576
            if mb >= 1 { return String(format: "%.0f MB", mb) }
            return "0 GB"
        }
        let tt = (o["memTotal"] as? NSNumber)?.doubleValue ?? 0

        // CPU
        if let c = o["cpu"] as? [String: Any], let t = (c["total"] as? NSNumber)?.doubleValue {
            let u = (c["user"] as? NSNumber)?.doubleValue
            let s = (c["sys"] as? NSNumber)?.doubleValue
            let cpuValStr: String
            if let u, let s {
                cpuValStr = String(format: "%.0f%% · %.1f / %.1f", t.rounded(), u, s)
            } else {
                cpuValStr = String(format: "%.1f%%", t)
            }
            cpuItem.title = "CPU " + cpuValStr
            cpuRow.set(value: cpuValStr, frac: t / 100, color: StatRowView.cpuColor)

            if let e = (c["eCores"] as? NSNumber)?.doubleValue,
               let p = (c["pCores"] as? NSNumber)?.doubleValue {
                cpuWaveRow.setSubtitle(String(format: "E %.0f%% (amber) / P %.0f%% (blue) · 30s", e.rounded(), p.rounded()))
            }
            cpuWaveRow.series1 = self.eCpuHist
            cpuWaveRow.series2 = self.pCpuHist
        }

        // Thermal
        if let th = o["thermal"] as? [String: Any] {
            let lvl = (th["level"] as? NSNumber)?.intValue ?? 0
            let state = (th["state"] as? String) ?? "nominal"
            let pretty = String(state.prefix(1)).uppercased() + String(state.dropFirst())
            let cpuTemp = (th["cpu"] as? NSNumber)?.doubleValue
            let tempStr: String? = cpuTemp.map { "\(Int($0.rounded()))°C" }
            let valStr = tempStr.map { "\(pretty) · \($0)" } ?? pretty
            thermalItem.title = "Thermal \(valStr)"
            // Two independent colours: the STATE word reflects the SMC throttle
            // level (nominal = the system isn't acting → neutral), and the
            // TEMPERATURE uses an absolute die-temp ramp (40°C green → 90°C+ red).
            let stateColor: NSColor = lvl == 0 ? .labelColor : (lvl == 1 ? .systemOrange : .systemRed)
            if let tRaw = cpuTemp {
                let frac = min(1, max(0, (Double(Int(tRaw.rounded())) - 40.0) / 50.0))
                let tempColor = NSColor(hue: (1.0 - frac) / 3.0, saturation: 0.72, brightness: 0.88, alpha: 1)
                thermalRow.set(state: pretty, value: tempStr!, stateColor: stateColor, valueColor: tempColor)
            } else {
                thermalRow.set(value: valStr, color: stateColor)
            }
        }

        // Load avg
        if let la = o["loadAvg"] as? [NSNumber], la.count >= 3 {
            let s = String(format: "%.2f · %.2f · %.2f", la[0].doubleValue, la[1].doubleValue, la[2].doubleValue)
            loadAvgItem.title = "Load avg " + s
            loadAvgRow.set(value: s)
        }

        // Uptime (amber >= 7d, coral-red >= 14d as a gentle reboot nudge)
        if let bt = (o["bootTime"] as? NSNumber)?.intValue, bt > 0 {
            let up = max(0, Int(Date().timeIntervalSince1970) - bt)
            let d = up / 86_400, h = (up % 86_400) / 3_600, m = (up % 3_600) / 60
            let upCol: NSColor = d >= 14 ? .systemRed : (d >= 7 ? .systemOrange : .labelColor)
            uptimeRow.set(value: d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m", color: upCol)
        }

        // GPU
        if let p = (o["gpuPct"] as? NSNumber)?.doubleValue {
            gpuItem.title = String(format: "GPU %.0f%%", p)
            gpuRow.set(value: String(format: "%.0f%%", p), frac: p / 100, color: StatRowView.gpuColor)
        } else {
            // Non-Apple-Silicon machine: keep the row, show nothing.
            gpuRow.set(value: "—", frac: 0, color: .clear)
        }
        if let gm = (o["gpuMem"] as? NSNumber)?.doubleValue {
            let gmStr = "\(fmtMem(gm)) in use"
            gpuMemItem.title = "GPU memory " + gmStr
            gpuMemRow.set(value: gmStr)
        } else {
            gpuMemRow.set(value: "—")
        }

        // Memory
        if let p = (o["memPct"] as? NSNumber)?.doubleValue,
           let u = (o["memUsed"] as? NSNumber)?.doubleValue,
           tt > 0 {
            let uGb = u / 1_073_741_824
            let ttGb = tt / 1_073_741_824
            let valStr = String(format: "%.1f / %.1f GB · %.0f%%", uGb, ttGb, p.rounded())
            memItem.title = "Memory " + valStr

            var segs: [SegmentedBarView.Segment] = []
            if let mp = o["memPools"] as? [String: Any] {
                let wired = (mp["wired"] as? NSNumber)?.doubleValue ?? 0
                let active = (mp["active"] as? NSNumber)?.doubleValue ?? 0
                let comp = (mp["compressed"] as? NSNumber)?.doubleValue ?? 0
                let free = (mp["free"] as? NSNumber)?.doubleValue ?? 0

                segs = [
                    .init(frac: wired / tt, color: StatusController.wiredColor),
                    .init(frac: active / tt, color: StatusController.activeColor),
                    .init(frac: comp / tt, color: StatusController.compColor),
                ]
                wiredRow.set(value: fmtMem(wired))
                activeRow.set(value: fmtMem(active))
                compRow.set(value: fmtMem(comp))
                freeRow.set(value: fmtMem(free))
            } else {
                segs = [.init(frac: p / 100, color: StatRowView.memColor)]
            }
            memRow.set(valueStr: valStr, segments: segs)
        }
        switch o["memPressure"] as? String {
        case "normal":
            memPressureRow.set(value: "Normal", color: NSColor(srgbRed: 0.18, green: 0.83, blue: 0.65, alpha: 1.0))
        case "warn":
            memPressureRow.set(value: "Warn", color: .systemOrange)
        case "critical":
            memPressureRow.set(value: "Critical", color: .systemRed)
        default:
            memPressureRow.set(value: "—", color: .secondaryLabelColor)
        }
        if let sw = (o["swapUsed"] as? NSNumber)?.doubleValue {
            if sw < 1_048_576 {
                swapRow.set(value: "0 MB", color: .secondaryLabelColor)
            } else {
                let swColor: NSColor = sw >= 4_294_967_296 ? .systemOrange : .labelColor
                swapRow.set(value: fmtMem(sw), color: swColor)
            }
        } else {
            swapRow.set(value: "—", color: .secondaryLabelColor)
        }

        // Network (bar-less info row showing both download and upload rates)
        if let n = o["net"] as? [String: Any] {
            let d = (n["down"] as? NSNumber)?.doubleValue ?? 0
            let u = (n["up"] as? NSNumber)?.doubleValue ?? 0
            netRow.set(value: "↓ \(Self.rate(d))/s · ↑ \(Self.rate(u))/s")
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
 *  Styled to match Pulse's dark card UI (#0b0d12 / #12151d / #171b25 / #232a38)
 * ================================================================== */
@MainActor
final class SettingsWindowController: NSObject {
    weak var shell: Shell?
    let window: NSWindow
    let startAtLoginSwitch = NSSwitch()
    let loginStatusLabel = NSTextField(labelWithString: "")
    private let bgCloseBtn = NSButton(title: "Keep in Menu Bar", target: nil, action: nil)
    private let quitCloseBtn = NSButton(title: "Quit Pulse", target: nil, action: nil)
    private var closeQuitSelected = false
    let keepMemSwitch = NSSwitch()

    private var menuRowSwitches: [String: NSSwitch] = [:]
    private var menuRowBarSwitches: [String: NSSwitch] = [:]
    private var menuRowUpButtons: [String: NSButton] = [:]
    private var menuRowDownButtons: [String: NSButton] = [:]
    private var menuRowDots: [String: NSView] = [:]
    private var menuRowLabels: [String: NSTextField] = [:]
    private var menuRowViews: [String: NSView] = [:]
    private let rowsBox = NSStackView()
    private let barPreviewImage = NSImageView()

    private let updateCheckButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
    private let updateVerLabel = NSTextField(labelWithString: "")
    private let updateStatusBadge = NSTextField(labelWithString: "")

    private var menuRowFull: [String] = PulseSettings.allMenuRows
    private var menuRowHidden = Set(PulseSettings.allMenuRows).subtracting(PulseSettings.defaultMenuRows)
    private var menuRowBarOn = Set(PulseSettings.defaultBarRows)

    private let bgDark = NSColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1)    // #0b0d12
    private let panelBg = NSColor(red: 0.071, green: 0.082, blue: 0.114, alpha: 1)   // #12151d
    private let cardBg = NSColor(red: 0.090, green: 0.106, blue: 0.145, alpha: 1)    // #171b25
    private let raisedBg = NSColor(red: 0.114, green: 0.137, blue: 0.196, alpha: 1)  // #1d2332
    private let borderCol = NSColor(red: 0.137, green: 0.165, blue: 0.220, alpha: 1) // #232a38
    private let textCol = NSColor(red: 0.910, green: 0.925, blue: 0.957, alpha: 1)   // #e8ecf4
    private let dimCol = NSColor(red: 0.545, green: 0.580, blue: 0.655, alpha: 1)    // #8b94a7
    private let faintCol = NSColor(red: 0.353, green: 0.388, blue: 0.459, alpha: 1)  // #5a6375
    private let accentGreen = NSColor(red: 0.176, green: 0.831, blue: 0.655, alpha: 1) // #2dd4a7
    private let accentOrange = NSColor(red: 1.0, green: 0.624, blue: 0.263, alpha: 1)  // #ff9f43
    private let accentBlue = NSColor(red: 0.302, green: 0.624, blue: 1.0, alpha: 1)    // #4d9fff
    private let accentGpu = NSColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1)   // #34c759

    private static let checkTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    init(shell: Shell) {
        self.shell = shell
        let rect = NSRect(x: 0, y: 0, width: 492, height: 676)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = panelBg
        window.isReleasedWhenClosed = false
        window.center()

        super.init()

        startAtLoginSwitch.controlSize = .small
        startAtLoginSwitch.target = self
        startAtLoginSwitch.action = #selector(onStartAtLoginChanged)

        keepMemSwitch.controlSize = .small
        keepMemSwitch.target = self
        keepMemSwitch.action = #selector(onKeepMemChanged)

        bgCloseBtn.target = self
        bgCloseBtn.action = #selector(onSelectBgClose)
        quitCloseBtn.target = self
        quitCloseBtn.action = #selector(onSelectQuitClose)

        updateCheckButton.target = shell
        updateCheckButton.action = #selector(Shell.checkForUpdates)

        buildLayout()
        syncFromState()
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text.uppercased())
        lbl.font = .systemFont(ofSize: 10, weight: .bold)
        lbl.textColor = faintCol
        return lbl
    }

    private func makeTitle(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 12.5, weight: .semibold)
        lbl.textColor = textCol
        return lbl
    }

    private func makeNote(_ text: String) -> NSTextField {
        let lbl = NSTextField(wrappingLabelWithString: text)
        lbl.font = .systemFont(ofSize: 11)
        lbl.textColor = dimCol
        lbl.maximumNumberOfLines = 2
        return lbl
    }

    private func makeCard(_ inner: NSView, padV: CGFloat = 12, padH: CGFloat = 14) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = cardBg.cgColor
        box.layer?.borderColor = borderCol.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 12
        box.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padH),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padH),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: padV),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padV),
        ])
        return box
    }

    private func makeHairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = borderCol.withAlphaComponent(0.8).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func styleActionBtn(_ btn: NSButton, accent: Bool) {
        btn.isBordered = false
        btn.wantsLayer = true
        btn.font = .systemFont(ofSize: 11.5, weight: .semibold)
        btn.contentTintColor = accent ? bgDark : textCol
        btn.layer?.backgroundColor = (accent ? accentOrange : panelBg).cgColor
        btn.layer?.cornerRadius = 7
        btn.layer?.borderColor = (accent ? accentOrange : borderCol).cgColor
        btn.layer?.borderWidth = 1
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 124).isActive = true
    }

    private func styleSegButtons() {
        for (btn, selected) in [(bgCloseBtn, !closeQuitSelected), (quitCloseBtn, closeQuitSelected)] {
            btn.isBordered = false
            btn.wantsLayer = true
            btn.font = .systemFont(ofSize: 11.5, weight: .semibold)
            btn.contentTintColor = selected ? textCol : dimCol
            btn.layer?.backgroundColor = (selected ? raisedBg : NSColor.clear).cgColor
            btn.layer?.borderColor = (selected ? NSColor(red: 0.20, green: 0.24, blue: 0.32, alpha: 1) : NSColor.clear).cgColor
            btn.layer?.borderWidth = 1
            btn.layer?.cornerRadius = 6
        }
    }

    private func metricColor(for id: String) -> NSColor {
        switch id {
        case "cpu": return accentOrange
        case "gpu": return accentGpu
        case "memory": return accentBlue
        case "network": return accentGreen
        default: return dimCol
        }
    }

    private func buildLayout() {
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.wantsLayer = true
        content.layer?.backgroundColor = panelBg.cgColor
        window.contentView = content

        // Header bar with icon + title
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(icon)

        let hTitle = NSTextField(labelWithString: "Settings")
        hTitle.font = .systemFont(ofSize: 15, weight: .bold)
        hTitle.textColor = textCol
        hTitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hTitle)

        let hSub = NSTextField(labelWithString: "Daemon lifecycle, menu bar capsules & updates")
        hSub.font = .systemFont(ofSize: 11.5)
        hSub.textColor = dimCol
        hSub.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hSub)

        let headerLine = makeHairline()
        content.addSubview(headerLine)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        // ── GENERAL GROUP ──
        let genLabel = makeSectionLabel("General")
        stack.addArrangedSubview(genLabel)

        let genInner = NSStackView()
        genInner.orientation = .vertical
        genInner.alignment = .leading
        genInner.spacing = 10

        // Row 1: Start at login
        let s1Left = NSStackView()
        s1Left.orientation = .vertical
        s1Left.alignment = .leading
        s1Left.spacing = 2
        let s1Header = NSStackView()
        s1Header.orientation = .horizontal
        s1Header.alignment = .centerY
        s1Header.spacing = 7
        loginStatusLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        s1Header.addArrangedSubview(makeTitle("Start at login"))
        s1Header.addArrangedSubview(loginStatusLabel)
        s1Left.addArrangedSubview(s1Header)
        s1Left.addArrangedSubview(makeNote("Keep metrics warm in the background via a macOS LaunchAgent."))
        let s1Row = NSStackView(views: [s1Left, startAtLoginSwitch])
        s1Row.orientation = .horizontal
        s1Row.alignment = .centerY
        s1Row.spacing = 12
        startAtLoginSwitch.setContentHuggingPriority(.required, for: .horizontal)

        // Row 2: Close behavior (custom dark segmented pill)
        let s2Col = NSStackView()
        s2Col.orientation = .vertical
        s2Col.alignment = .leading
        s2Col.spacing = 7
        s2Col.addArrangedSubview(makeTitle("When closing the window"))
        let segWrap = NSView()
        segWrap.wantsLayer = true
        segWrap.layer?.backgroundColor = bgDark.cgColor
        segWrap.layer?.borderColor = borderCol.cgColor
        segWrap.layer?.borderWidth = 1
        segWrap.layer?.cornerRadius = 8
        segWrap.translatesAutoresizingMaskIntoConstraints = false
        let segRow = NSStackView(views: [bgCloseBtn, quitCloseBtn])
        segRow.orientation = .horizontal
        segRow.distribution = .fillEqually
        segRow.spacing = 4
        segRow.translatesAutoresizingMaskIntoConstraints = false
        segWrap.addSubview(segRow)
        for b in [bgCloseBtn, quitCloseBtn] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        NSLayoutConstraint.activate([
            segRow.leadingAnchor.constraint(equalTo: segWrap.leadingAnchor, constant: 3),
            segRow.trailingAnchor.constraint(equalTo: segWrap.trailingAnchor, constant: -3),
            segRow.topAnchor.constraint(equalTo: segWrap.topAnchor, constant: 3),
            segRow.bottomAnchor.constraint(equalTo: segWrap.bottomAnchor, constant: -3),
        ])
        s2Col.addArrangedSubview(segWrap)
        segWrap.widthAnchor.constraint(equalTo: s2Col.widthAnchor).isActive = true

        // Row 3: Keep dashboard in memory
        let s3Left = NSStackView()
        s3Left.orientation = .vertical
        s3Left.alignment = .leading
        s3Left.spacing = 2
        let s3TitleRow = NSStackView()
        s3TitleRow.orientation = .horizontal
        s3TitleRow.alignment = .centerY
        s3TitleRow.spacing = 7
        let memBadge = NSTextField(labelWithString: "Off saves ~120 MB")
        memBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        memBadge.textColor = accentBlue
        s3TitleRow.addArrangedSubview(makeTitle("Keep dashboard in memory"))
        s3TitleRow.addArrangedSubview(memBadge)
        s3Left.addArrangedSubview(s3TitleRow)
        s3Left.addArrangedSubview(makeNote("Release WebKit helpers on close and reload in <0.5s when reopened."))
        let s3Row = NSStackView(views: [s3Left, keepMemSwitch])
        s3Row.orientation = .horizontal
        s3Row.alignment = .centerY
        s3Row.spacing = 12
        keepMemSwitch.setContentHuggingPriority(.required, for: .horizontal)

        let sep1 = makeHairline()
        let sep2 = makeHairline()
        genInner.addArrangedSubview(s1Row)
        genInner.addArrangedSubview(sep1)
        genInner.addArrangedSubview(s2Col)
        genInner.addArrangedSubview(sep2)
        genInner.addArrangedSubview(s3Row)
        for v in [s1Row, sep1, s2Col, sep2, s3Row] {
            v.widthAnchor.constraint(equalTo: genInner.widthAnchor).isActive = true
        }
        let genCard = makeCard(genInner)
        stack.addArrangedSubview(genCard)
        genCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ── MENU BAR & DROPDOWN ──
        stack.setCustomSpacing(14, after: genCard)
        stack.addArrangedSubview(makeSectionLabel("Menu Bar & Dropdown"))

        let s4Col = NSStackView()
        s4Col.orientation = .vertical
        s4Col.alignment = .leading
        s4Col.spacing = 8

        // Live Menu Bar Capsule Preview rendered by StatusController.render(...)
        let previewWrap = NSView()
        previewWrap.wantsLayer = true
        previewWrap.layer?.backgroundColor = bgDark.cgColor
        previewWrap.layer?.borderColor = borderCol.cgColor
        previewWrap.layer?.borderWidth = 1
        previewWrap.layer?.cornerRadius = 9
        previewWrap.translatesAutoresizingMaskIntoConstraints = false
        let prevLbl = NSTextField(labelWithString: "BAR PREVIEW")
        prevLbl.font = .systemFont(ofSize: 9.5, weight: .bold)
        prevLbl.textColor = faintCol
        prevLbl.translatesAutoresizingMaskIntoConstraints = false
        barPreviewImage.imageScaling = .scaleNone
        barPreviewImage.translatesAutoresizingMaskIntoConstraints = false
        let pillFrame = NSView()
        pillFrame.wantsLayer = true
        pillFrame.layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
        pillFrame.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        pillFrame.layer?.borderWidth = 1
        pillFrame.layer?.cornerRadius = 6
        pillFrame.translatesAutoresizingMaskIntoConstraints = false
        pillFrame.addSubview(barPreviewImage)
        previewWrap.addSubview(prevLbl)
        previewWrap.addSubview(pillFrame)
        NSLayoutConstraint.activate([
            previewWrap.heightAnchor.constraint(equalToConstant: 36),
            prevLbl.leadingAnchor.constraint(equalTo: previewWrap.leadingAnchor, constant: 10),
            prevLbl.centerYAnchor.constraint(equalTo: previewWrap.centerYAnchor),
            pillFrame.trailingAnchor.constraint(equalTo: previewWrap.trailingAnchor, constant: -8),
            pillFrame.centerYAnchor.constraint(equalTo: previewWrap.centerYAnchor),
            pillFrame.heightAnchor.constraint(equalToConstant: 24),
            barPreviewImage.leadingAnchor.constraint(equalTo: pillFrame.leadingAnchor, constant: 8),
            barPreviewImage.trailingAnchor.constraint(equalTo: pillFrame.trailingAnchor, constant: -8),
            barPreviewImage.centerYAnchor.constraint(equalTo: pillFrame.centerYAnchor),
        ])
        s4Col.addArrangedSubview(previewWrap)
        previewWrap.widthAnchor.constraint(equalTo: s4Col.widthAnchor).isActive = true

        // Column header row
        let colHead = NSStackView()
        colHead.orientation = .horizontal
        colHead.alignment = .centerY
        colHead.spacing = 8
        let mkColHdr = { (t: String, w: CGFloat) -> NSTextField in
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 9.5, weight: .bold)
            l.textColor = self.faintCol
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: w).isActive = true
            return l
        }
        let mNameHdr = NSTextField(labelWithString: "METRIC")
        mNameHdr.font = .systemFont(ofSize: 9.5, weight: .bold)
        mNameHdr.textColor = faintCol
        mNameHdr.setContentHuggingPriority(.defaultLow, for: .horizontal)
        colHead.addArrangedSubview(mNameHdr)
        colHead.addArrangedSubview(mkColHdr("MENU", 44))
        colHead.addArrangedSubview(mkColHdr("BAR", 44))
        colHead.addArrangedSubview(mkColHdr("ORDER", 46))
        s4Col.addArrangedSubview(colHead)
        colHead.widthAnchor.constraint(equalTo: s4Col.widthAnchor).isActive = true

        rowsBox.orientation = .vertical
        rowsBox.alignment = .leading
        rowsBox.spacing = 4
        let rowLabels: [String: String] = ["cpu": "CPU", "gpu": "GPU", "memory": "Memory", "network": "Network", "uptime": "Uptime"]
        let rowTags: [String: String] = ["cpu": "+ thermal", "uptime": "menu only"]

        for id in PulseSettings.allMenuRows {
            let barCapable = PulseSettings.allBarRows.contains(id)
            let rowWrap = NSView()
            rowWrap.wantsLayer = true
            rowWrap.layer?.backgroundColor = bgDark.withAlphaComponent(0.55).cgColor
            rowWrap.layer?.cornerRadius = 7
            rowWrap.translatesAutoresizingMaskIntoConstraints = false

            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = metricColor(for: id).cgColor
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true

            let lbl = NSTextField(labelWithString: rowLabels[id] ?? id)
            lbl.font = .systemFont(ofSize: 12, weight: .medium)
            lbl.textColor = textCol

            let nameStack = NSStackView(views: [dot, lbl])
            nameStack.orientation = .horizontal
            nameStack.alignment = .centerY
            nameStack.spacing = 7
            if let tagText = rowTags[id] {
                let tag = NSTextField(labelWithString: tagText)
                tag.font = .systemFont(ofSize: 10)
                tag.textColor = faintCol
                nameStack.addArrangedSubview(tag)
            }
            nameStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nameStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let sw = NSSwitch()
            sw.controlSize = .small
            sw.target = self
            sw.action = #selector(onMenuRowSwitch)
            sw.translatesAutoresizingMaskIntoConstraints = false
            let swBox = NSView()
            swBox.translatesAutoresizingMaskIntoConstraints = false
            swBox.addSubview(sw)
            NSLayoutConstraint.activate([
                swBox.widthAnchor.constraint(equalToConstant: 44),
                swBox.heightAnchor.constraint(equalToConstant: 22),
                sw.centerXAnchor.constraint(equalTo: swBox.centerXAnchor),
                sw.centerYAnchor.constraint(equalTo: swBox.centerYAnchor),
            ])

            let barBox = NSView()
            barBox.translatesAutoresizingMaskIntoConstraints = false
            barBox.widthAnchor.constraint(equalToConstant: 44).isActive = true
            barBox.heightAnchor.constraint(equalToConstant: 22).isActive = true
            if barCapable {
                let bsw = NSSwitch()
                bsw.controlSize = .small
                bsw.target = self
                bsw.action = #selector(onMenuRowBarSwitch)
                bsw.translatesAutoresizingMaskIntoConstraints = false
                barBox.addSubview(bsw)
                NSLayoutConstraint.activate([
                    bsw.centerXAnchor.constraint(equalTo: barBox.centerXAnchor),
                    bsw.centerYAnchor.constraint(equalTo: barBox.centerYAnchor),
                ])
                menuRowBarSwitches[id] = bsw
            } else {
                let dash = NSTextField(labelWithString: "—")
                dash.font = .systemFont(ofSize: 11)
                dash.textColor = faintCol
                dash.translatesAutoresizingMaskIntoConstraints = false
                barBox.addSubview(dash)
                NSLayoutConstraint.activate([
                    dash.centerXAnchor.constraint(equalTo: barBox.centerXAnchor),
                    dash.centerYAnchor.constraint(equalTo: barBox.centerYAnchor),
                ])
            }

            let up = NSButton(title: "", target: self, action: #selector(onMenuRowUp))
            let dn = NSButton(title: "", target: self, action: #selector(onMenuRowDown))
            up.identifier = NSUserInterfaceItemIdentifier(id)
            dn.identifier = NSUserInterfaceItemIdentifier(id)
            up.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up")
            dn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down")
            for b in [up, dn] {
                b.imagePosition = .imageOnly
                b.isBordered = false
                b.wantsLayer = true
                b.layer?.backgroundColor = panelBg.cgColor
                b.layer?.borderColor = borderCol.cgColor
                b.layer?.borderWidth = 1
                b.layer?.cornerRadius = 5
                b.contentTintColor = dimCol
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 21).isActive = true
                b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            }
            let ordStack = NSStackView(views: [up, dn])
            ordStack.orientation = .horizontal
            ordStack.spacing = 4
            ordStack.translatesAutoresizingMaskIntoConstraints = false
            ordStack.widthAnchor.constraint(equalToConstant: 46).isActive = true

            let row = NSStackView(views: [nameStack, swBox, barBox, ordStack])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            rowWrap.addSubview(row)
            NSLayoutConstraint.activate([
                rowWrap.heightAnchor.constraint(equalToConstant: 31),
                row.leadingAnchor.constraint(equalTo: rowWrap.leadingAnchor, constant: 10),
                row.trailingAnchor.constraint(equalTo: rowWrap.trailingAnchor, constant: -8),
                row.centerYAnchor.constraint(equalTo: rowWrap.centerYAnchor),
            ])

            menuRowSwitches[id] = sw
            menuRowUpButtons[id] = up
            menuRowDownButtons[id] = dn
            menuRowDots[id] = dot
            menuRowLabels[id] = lbl
            menuRowViews[id] = rowWrap
            rowsBox.addArrangedSubview(rowWrap)
            rowWrap.widthAnchor.constraint(equalTo: rowsBox.widthAnchor).isActive = true
        }
        s4Col.addArrangedSubview(rowsBox)
        rowsBox.widthAnchor.constraint(equalTo: s4Col.widthAnchor).isActive = true
        let card4 = makeCard(s4Col, padV: 12, padH: 12)
        stack.addArrangedSubview(card4)
        card4.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ── UPDATES ──
        stack.setCustomSpacing(14, after: card4)
        stack.addArrangedSubview(makeSectionLabel("Updates"))

        let s5Left = NSStackView()
        s5Left.orientation = .vertical
        s5Left.alignment = .leading
        s5Left.spacing = 3
        let s5TitleRow = NSStackView()
        s5TitleRow.orientation = .horizontal
        s5TitleRow.alignment = .centerY
        s5TitleRow.spacing = 7
        updateVerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        updateVerLabel.textColor = dimCol
        updateStatusBadge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        s5TitleRow.addArrangedSubview(makeTitle("Pulse Updates"))
        s5TitleRow.addArrangedSubview(updateVerLabel)
        s5TitleRow.addArrangedSubview(updateStatusBadge)
        s5Left.addArrangedSubview(s5TitleRow)
        s5Left.addArrangedSubview(makeNote("Checks automatically on launch, or check manually anytime."))
        styleActionBtn(updateCheckButton, accent: false)
        let s5Row = NSStackView(views: [s5Left, updateCheckButton])
        s5Row.orientation = .horizontal
        s5Row.alignment = .centerY
        s5Row.spacing = 12
        updateCheckButton.setContentHuggingPriority(.required, for: .horizontal)
        let card5 = makeCard(s5Row)
        stack.addArrangedSubview(card5)
        card5.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            header.heightAnchor.constraint(equalToConstant: 44),

            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),

            hTitle.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            hTitle.topAnchor.constraint(equalTo: icon.topAnchor, constant: -1),
            hSub.leadingAnchor.constraint(equalTo: hTitle.leadingAnchor),
            hSub.topAnchor.constraint(equalTo: hTitle.bottomAnchor, constant: 1),

            headerLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),

            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: headerLine.bottomAnchor, constant: 14),
        ])
    }

    func syncFromState() {
        guard let shell else { return }
        let mgr = LaunchAgentManager.shared
        let loaded = mgr.cachedIsLoaded
        let configured = mgr.isTransitioning ? shell.settings.startAtLogin : (loaded || mgr.plistExists)
        startAtLoginSwitch.state = configured ? .on : .off
        if let err = mgr.lastError, !err.isEmpty {
            loginStatusLabel.stringValue = "● Error: \(err.prefix(28))"
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
        closeQuitSelected = shell.settings.shouldQuitOnClose
        styleSegButtons()
        keepMemSwitch.state = shell.settings.keepDashboardInMemory ? .on : .off

        let vis = shell.settings.menuRows
        let known = PulseSettings.allMenuRows
        let prevHidden = menuRowFull.filter { menuRowHidden.contains($0) && !vis.contains($0) }
        let hidden = prevHidden + known.filter { !vis.contains($0) && !prevHidden.contains($0) }
        menuRowHidden = Set(hidden)
        let projected = menuRowFull.filter { !menuRowHidden.contains($0) }
        if projected != vis {
            menuRowFull = vis + hidden
        }
        let bar = shell.settings.barRows
        if Set(bar) != menuRowBarOn { menuRowBarOn = Set(bar) }

        let currentVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        updateVerLabel.stringValue = "v\(currentVer)"
        if let ver = shell.pendingUpdateVersion {
            updateStatusBadge.stringValue = "v\(ver) available"
            updateStatusBadge.textColor = accentOrange
            updateCheckButton.title = "Update to v\(ver)…"
            styleActionBtn(updateCheckButton, accent: true)
            updateCheckButton.isEnabled = true
        } else if shell.updateChecking {
            updateStatusBadge.stringValue = "Checking…"
            updateStatusBadge.textColor = accentOrange
            updateCheckButton.title = "Checking…"
            styleActionBtn(updateCheckButton, accent: false)
            updateCheckButton.isEnabled = false
        } else if shell.lastCheckFailed {
            updateStatusBadge.stringValue = "Couldn't check"
            updateStatusBadge.textColor = accentOrange
            updateCheckButton.title = "Try again"
            styleActionBtn(updateCheckButton, accent: false)
            updateCheckButton.isEnabled = true
        } else {
            if let ms = shell.lastCheckAtMs {
                let when = Self.checkTimeFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
                updateStatusBadge.stringValue = "Up to date · \(when)"
            } else {
                updateStatusBadge.stringValue = "Up to date"
            }
            updateStatusBadge.textColor = accentGreen
            updateCheckButton.title = "Check for Updates…"
            styleActionBtn(updateCheckButton, accent: false)
            updateCheckButton.isEnabled = true
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

    @objc private func onSelectBgClose() {
        closeQuitSelected = false
        styleSegButtons()
        shell?.setCloseBehavior("background")
    }

    @objc private func onSelectQuitClose() {
        closeQuitSelected = true
        styleSegButtons()
        shell?.setCloseBehavior("quit")
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

    @objc private func onMenuRowUp(_ sender: NSButton) {
        moveMenuRow(sender.identifier?.rawValue, -1)
    }

    @objc private func onMenuRowDown(_ sender: NSButton) {
        moveMenuRow(sender.identifier?.rawValue, 1)
    }

    private func moveMenuRow(_ id: String?, _ dir: Int) {
        guard let id, let i = menuRowFull.firstIndex(of: id) else { return }
        let j = i + dir
        guard menuRowFull.indices.contains(j) else { return }
        menuRowFull.swapAt(i, j)
        rebuildMenuRowsUI()
        pushMenuRows()
    }

    private func rebuildMenuRowsUI() {
        // Reorder row views visually inside rowsBox to match menuRowFull
        for v in rowsBox.arrangedSubviews {
            rowsBox.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (idx, id) in menuRowFull.enumerated() {
            if let v = menuRowViews[id] {
                rowsBox.addArrangedSubview(v)
                v.widthAnchor.constraint(equalTo: rowsBox.widthAnchor).isActive = true
            }
            let up = menuRowUpButtons[id]
            let dn = menuRowDownButtons[id]
            up?.isEnabled = idx > 0
            dn?.isEnabled = idx < menuRowFull.count - 1
            up?.alphaValue = idx > 0 ? 1.0 : 0.3
            dn?.alphaValue = idx < menuRowFull.count - 1 ? 1.0 : 0.3
        }
        for (id, sw) in menuRowSwitches {
            let hidden = menuRowHidden.contains(id)
            sw.state = hidden ? .off : .on
            menuRowLabels[id]?.textColor = hidden ? dimCol : textCol
            menuRowDots[id]?.layer?.opacity = hidden ? 0.35 : 1.0
        }
        for (id, sw) in menuRowBarSwitches {
            sw.state = menuRowBarOn.contains(id) ? .on : .off
        }
        // Live status bar preview using the exact StatusController.render(...) engine
        let vis = menuRowFull.filter { !menuRowHidden.contains($0) }
        let bar = PulseSettings.allBarRows.filter { menuRowBarOn.contains($0) }
        let orderedBar = menuRowFull.filter { bar.contains($0) }
        barPreviewImage.image = StatusController.render(
            cpu: [28, 42, 35, 58, 46],
            mem: [41, 41, 41],
            gpu: [14, 22, 18],
            net: [12, 24, 18],
            netText: StatusController.netText(down: 1_240_000, up: 86_000),
            menu: vis,
            bar: orderedBar
        )
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
/// A clickable, text-labeled update strip — the quiet "an update is available"
/// ribbon along the window's top edge. `Shell.syncUpdateStrip()` anchors it and
/// keeps the webview *below* it, so the dashboard reflows instead of being covered.
final class UpdateStripView: NSView {
    /// Strip height — the exact space the webview reserves when the strip shows.
    static let height: CGFloat = 24
    private let labelField = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var labelFrame: NSRect { labelField.frame }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        // The web palette's --net green, with dark ink on it: white on this mint
        // is only ~2:1 contrast, the dark ink is ~7:1 — readable at a glance.
        layer?.backgroundColor = NSColor(srgbRed: 0x2d / 255.0, green: 0xd4 / 255.0, blue: 0xa7 / 255.0, alpha: 1).cgColor
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.alignment = .center
        labelField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = NSColor(srgbRed: 0x07 / 255.0, green: 0x30 / 255.0, blue: 0x1f / 255.0, alpha: 1)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)
        // Centered label; the leading/trailing clamp only kicks in on absurdly
        // narrow windows (min is 940, the label is ~260 — it never binds).
        NSLayoutConstraint.activate([
            labelField.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    func setVersion(_ version: String?) {
        if let v = version {
            labelField.stringValue = "Pulse \(v) is available — click to update"
            isHidden = false
            toolTip = "Update to Pulse \(v)"
        } else {
            labelField.stringValue = ""
            isHidden = true
            toolTip = nil
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Custom Pulse-styled About window (#12151d / #171b25 / #232a38 / #ff9f43).
@MainActor
final class PulseAboutWindowController: NSObject {
    weak var shell: Shell?
    let window: NSWindow

    private let panelBg = NSColor(red: 0.071, green: 0.082, blue: 0.114, alpha: 1)  // #12151d
    private let cardBg = NSColor(red: 0.090, green: 0.106, blue: 0.145, alpha: 1)   // #171b25
    private let borderCol = NSColor(red: 0.137, green: 0.165, blue: 0.220, alpha: 1) // #232a38
    private let textCol = NSColor(red: 0.910, green: 0.925, blue: 0.957, alpha: 1)   // #e8ecf4
    private let dimCol = NSColor(red: 0.545, green: 0.580, blue: 0.655, alpha: 1)    // #8b94a7
    private let accentOrange = NSColor(red: 1.0, green: 0.624, blue: 0.263, alpha: 1) // #ff9f43

    init(shell: Shell) {
        self.shell = shell
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 278),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = panelBg
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = panelBg.cgColor
        window.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 76),
            icon.heightAnchor.constraint(equalToConstant: 76),
        ])

        let title = NSTextField(labelWithString: "Pulse")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = textCol

        let verStr = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = cardBg.cgColor
        pill.layer?.borderColor = borderCol.cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.cornerRadius = 9
        pill.translatesAutoresizingMaskIntoConstraints = false
        let verLabel = NSTextField(labelWithString: "v\(verStr)")
        verLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        verLabel.textColor = accentOrange
        verLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(verLabel)
        NSLayoutConstraint.activate([
            verLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            verLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            verLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            verLabel.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
        ])

        let subtitle = NSTextField(labelWithString: "Real-time macOS resource monitor")
        subtitle.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.textColor = dimCol

        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 10

        let ghBtn = makePillButton(title: "GitHub", primary: false, action: #selector(openGitHub))
        let updBtn = makePillButton(title: "Check for Updates…", primary: true, action: #selector(checkUpdates))
        btnRow.addArrangedSubview(ghBtn)
        btnRow.addArrangedSubview(updBtn)

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        stack.addArrangedSubview(pill)
        stack.setCustomSpacing(8, after: pill)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(18, after: subtitle)
        stack.addArrangedSubview(btnRow)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 4),
        ])
    }

    private func makePillButton(title: String, primary: Bool, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.font = .systemFont(ofSize: 12, weight: .semibold)
        btn.contentTintColor = primary ? NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1) : textCol
        btn.layer?.backgroundColor = (primary ? accentOrange : cardBg).cgColor
        btn.layer?.cornerRadius = 8
        if !primary {
            btn.layer?.borderColor = borderCol.cgColor
            btn.layer?.borderWidth = 1
        }
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 30),
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: primary ? 144 : 88),
        ])
        return btn
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/ssa17/pulse") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkUpdates() {
        window.close()
        shell?.checkForUpdates()
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Custom Pulse-styled Sparkle update window (#12151d / #171b25 / #232a38 / #ff9f43).
/// Replaces Sparkle's dated stock modals ("Remind Me Later", "Skip This Version",
/// "Automatically download...") with a clean dark UI matching the dashboard.
@MainActor
final class PulseUpdateWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow

    private let panelBg = NSColor(red: 0.071, green: 0.082, blue: 0.114, alpha: 1)  // #12151d
    private let cardBg = NSColor(red: 0.090, green: 0.106, blue: 0.145, alpha: 1)   // #171b25
    private let borderCol = NSColor(red: 0.137, green: 0.165, blue: 0.220, alpha: 1) // #232a38
    private let textCol = NSColor(red: 0.910, green: 0.925, blue: 0.957, alpha: 1)   // #e8ecf4
    private let dimCol = NSColor(red: 0.545, green: 0.580, blue: 0.655, alpha: 1)    // #8b94a7
    private let accentOrange = NSColor(red: 1.0, green: 0.624, blue: 0.263, alpha: 1) // #ff9f43

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let notesCard = NSView()
    private let notesScroll = NSScrollView()
    private let notesTextView = NSTextView()
    private let progressWrap = NSView()
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressFillWidth: NSLayoutConstraint!
    private let progressLabel = NSTextField(labelWithString: "")
    private let secondaryBtn = NSButton(title: "Later", target: nil, action: nil)
    private let primaryBtn = NSButton(title: "Update", target: nil, action: nil)

    private var checkCancel: (() -> Void)?
    private var downloadCancel: (() -> Void)?
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var errorAck: (() -> Void)?
    private var permReply: ((SUUpdatePermissionResponse) -> Void)?

    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var isProgrammaticClose = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 452, height: 182),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = panelBg
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        window.delegate = self
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = panelBg.cgColor
        window.contentView = root

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = textCol
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = dimCol
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(subtitleLabel)

        // Release notes / message card
        notesCard.wantsLayer = true
        notesCard.layer?.backgroundColor = cardBg.cgColor
        notesCard.layer?.borderColor = borderCol.cgColor
        notesCard.layer?.borderWidth = 1
        notesCard.layer?.cornerRadius = 10
        notesCard.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(notesCard)

        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesScroll.borderType = .noBorder
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        notesCard.addSubview(notesScroll)

        notesTextView.isEditable = false
        notesTextView.isSelectable = true
        notesTextView.drawsBackground = false
        notesTextView.textContainerInset = NSSize(width: 8, height: 8)
        notesTextView.font = .systemFont(ofSize: 12)
        notesTextView.textColor = textCol
        notesTextView.isVerticallyResizable = true
        notesTextView.isHorizontallyResizable = false
        notesTextView.autoresizingMask = [.width]
        notesTextView.textContainer?.widthTracksTextView = true
        notesScroll.documentView = notesTextView

        // Progress bar area
        progressWrap.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(progressWrap)

        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = cardBg.cgColor
        progressTrack.layer?.borderColor = borderCol.cgColor
        progressTrack.layer?.borderWidth = 1
        progressTrack.layer?.cornerRadius = 4
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressWrap.addSubview(progressTrack)

        progressFill.wantsLayer = true
        progressFill.layer?.backgroundColor = accentOrange.cgColor
        progressFill.layer?.cornerRadius = 3
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        progressFillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progressLabel.textColor = dimCol
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressWrap.addSubview(progressLabel)

        // Footer buttons
        styleButton(secondaryBtn, primary: false)
        secondaryBtn.target = self
        secondaryBtn.action = #selector(onSecondary)
        root.addSubview(secondaryBtn)

        styleButton(primaryBtn, primary: true)
        primaryBtn.target = self
        primaryBtn.action = #selector(onPrimary)
        root.addSubview(primaryBtn)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            titleLabel.topAnchor.constraint(equalTo: icon.topAnchor, constant: 3),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            notesCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            notesCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            notesCard.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
            notesCard.bottomAnchor.constraint(equalTo: secondaryBtn.topAnchor, constant: -16),

            notesScroll.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 4),
            notesScroll.trailingAnchor.constraint(equalTo: notesCard.trailingAnchor, constant: -4),
            notesScroll.topAnchor.constraint(equalTo: notesCard.topAnchor, constant: 4),
            notesScroll.bottomAnchor.constraint(equalTo: notesCard.bottomAnchor, constant: -4),

            progressWrap.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            progressWrap.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            progressWrap.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            progressWrap.heightAnchor.constraint(equalToConstant: 36),

            progressTrack.leadingAnchor.constraint(equalTo: progressWrap.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: progressWrap.trailingAnchor),
            progressTrack.topAnchor.constraint(equalTo: progressWrap.topAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 8),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressFillWidth,

            progressLabel.leadingAnchor.constraint(equalTo: progressWrap.leadingAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: progressWrap.trailingAnchor),
            progressLabel.topAnchor.constraint(equalTo: progressTrack.bottomAnchor, constant: 8),

            primaryBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            primaryBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            primaryBtn.heightAnchor.constraint(equalToConstant: 30),
            primaryBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            secondaryBtn.trailingAnchor.constraint(equalTo: primaryBtn.leadingAnchor, constant: -10),
            secondaryBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            secondaryBtn.heightAnchor.constraint(equalToConstant: 30),
            secondaryBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ])
    }

    private func styleButton(_ btn: NSButton, primary: Bool) {
        btn.isBordered = false
        btn.wantsLayer = true
        btn.font = .systemFont(ofSize: 12, weight: .semibold)
        btn.contentTintColor = primary ? NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1) : textCol
        btn.layer?.backgroundColor = (primary ? accentOrange : cardBg).cgColor
        btn.layer?.cornerRadius = 8
        if !primary {
            btn.layer?.borderColor = borderCol.cgColor
            btn.layer?.borderWidth = 1
        }
        btn.translatesAutoresizingMaskIntoConstraints = false
    }

    private func resize(width: CGFloat = 452, height: CGFloat) {
        var f = window.frame
        let dy = height - f.height
        f.origin.y -= dy
        f.size.width = width
        f.size.height = height
        window.setFrame(f, display: true, animate: false)
    }

    private func present() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func clearCallbacks() {
        checkCancel = nil
        downloadCancel = nil
        updateReply = nil
        readyReply = nil
        errorAck = nil
        permReply = nil
    }

    private func setNotesPlain(_ text: String) {
        notesTextView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: textCol,
            ]
        ))
    }

    private func setNotesHTML(_ data: Data) {
        if let attr = try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) {
            let full = NSRange(location: 0, length: attr.length)
            attr.addAttribute(.foregroundColor, value: textCol, range: full)
            attr.enumerateAttribute(.font, in: full) { val, r, _ in
                if let f = val as? NSFont {
                    let isBold = f.fontDescriptor.symbolicTraits.contains(.bold)
                    let sz = max(11.5, min(14, f.pointSize))
                    attr.addAttribute(.font, value: NSFont.systemFont(ofSize: sz, weight: isBold ? .semibold : .regular), range: r)
                }
            }
            notesTextView.textStorage?.setAttributedString(attr)
        }
    }

    // MARK: Sparkle driver states

    func showChecking(cancellation: @escaping () -> Void) {
        clearCallbacks()
        checkCancel = cancellation
        titleLabel.stringValue = "Checking for Updates…"
        subtitleLabel.stringValue = "Contacting update feed"
        notesCard.isHidden = true
        progressWrap.isHidden = false
        progressFillWidth.constant = 160
        progressLabel.stringValue = "Fetching latest release info…"
        primaryBtn.isHidden = true
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Cancel"
        resize(height: 176)
        present()
    }

    func showPermission(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        clearCallbacks()
        permReply = reply
        titleLabel.stringValue = "Automatic Updates"
        subtitleLabel.stringValue = "Keep Pulse up to date automatically"
        notesCard.isHidden = false
        progressWrap.isHidden = true
        setNotesPlain("Pulse can check for new releases in the background and notify you when an update is ready.")
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Not Now"
        primaryBtn.isHidden = false
        primaryBtn.title = "Enable Checks"
        resize(height: 230)
        present()
    }

    func showUpdateFound(item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        clearCallbacks()
        updateReply = reply
        let curVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let newVer = item.displayVersionString
        let sizeStr = item.contentLength > 0
            ? " · " + ByteCountFormatter.string(fromByteCount: Int64(item.contentLength), countStyle: .file)
            : ""
        titleLabel.stringValue = "Pulse v\(newVer) Available"
        subtitleLabel.stringValue = "You have v\(curVer)\(sizeStr)"
        notesCard.isHidden = false
        progressWrap.isHidden = true

        if let desc = item.itemDescription, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let data = desc.data(using: .utf8), desc.contains("<") {
                setNotesHTML(data)
            } else {
                setNotesPlain(desc)
            }
        } else {
            setNotesPlain("A new version of Pulse is ready to download and install.")
        }

        secondaryBtn.isHidden = false
        secondaryBtn.title = "Later"
        primaryBtn.isHidden = false
        primaryBtn.title = state.stage == .downloaded ? "Install & Relaunch" : "Update & Relaunch"
        resize(height: 320)
        present()
    }

    func showReleaseNotes(_ data: SPUDownloadData) {
        setNotesHTML(data.data)
    }

    // MARK: Dev-only screen preview helpers (PULSE_PREVIEW=1)

    func showPreviewAvailable(version: String, sizeBytes: UInt64, htmlNotes: String) {
        clearCallbacks()
        let curVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.5"
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
        titleLabel.stringValue = "Pulse v\(version) Available"
        subtitleLabel.stringValue = "You have v\(curVer) · \(sizeStr)"
        notesCard.isHidden = false
        progressWrap.isHidden = true
        if let data = htmlNotes.data(using: .utf8) { setNotesHTML(data) }
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Later"
        primaryBtn.isHidden = false
        primaryBtn.title = "Update & Relaunch"
        updateReply = { [weak self] _ in self?.dismiss() }
        resize(height: 320)
        present()
    }

    func showPreviewPermission() {
        clearCallbacks()
        titleLabel.stringValue = "Automatic Updates"
        subtitleLabel.stringValue = "Keep Pulse up to date automatically"
        notesCard.isHidden = false
        progressWrap.isHidden = true
        setNotesPlain("Pulse can check for new releases in the background and notify you when an update is ready.")
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Not Now"
        primaryBtn.isHidden = false
        primaryBtn.title = "Enable Checks"
        permReply = { [weak self] _ in self?.dismiss() }
        resize(height: 230)
        present()
    }

    func showDownloadStarted(cancellation: @escaping () -> Void) {
        clearCallbacks()
        downloadCancel = cancellation
        expectedBytes = 0
        receivedBytes = 0
        titleLabel.stringValue = "Downloading Update…"
        subtitleLabel.stringValue = "Pulse will verify the signature before installing"
        notesCard.isHidden = true
        progressWrap.isHidden = false
        progressFillWidth.constant = 16
        progressLabel.stringValue = "Starting download…"
        primaryBtn.isHidden = true
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Cancel"
        resize(height: 176)
        present()
    }

    func setExpectedLength(_ len: UInt64) {
        expectedBytes = len
        updateDownloadProgress()
    }

    func addReceivedBytes(_ len: UInt64) {
        receivedBytes += len
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        let trackW = max(1, progressTrack.bounds.width > 0 ? progressTrack.bounds.width : 408)
        if expectedBytes > 0 {
            let frac = min(1.0, Double(receivedBytes) / Double(expectedBytes))
            progressFillWidth.constant = max(8, trackW * frac)
            let got = ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file)
            let tot = ByteCountFormatter.string(fromByteCount: Int64(expectedBytes), countStyle: .file)
            progressLabel.stringValue = "\(got) of \(tot) (\(Int(frac * 100))%)"
        } else {
            let got = ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file)
            progressLabel.stringValue = "Downloaded \(got)…"
        }
    }

    func showExtracting() {
        downloadCancel = nil
        titleLabel.stringValue = "Preparing Update…"
        subtitleLabel.stringValue = "Extracting and verifying signature"
        progressFillWidth.constant = 0
        progressLabel.stringValue = "Extracting…"
        secondaryBtn.isHidden = true
        primaryBtn.isHidden = true
    }

    func setExtractionProgress(_ progress: Double) {
        let trackW = max(1, progressTrack.bounds.width > 0 ? progressTrack.bounds.width : 408)
        progressFillWidth.constant = max(8, trackW * min(1.0, max(0.0, progress)))
        progressLabel.stringValue = "Extracting… \(Int(progress * 100))%"
    }

    func showReady(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        clearCallbacks()
        readyReply = reply
        titleLabel.stringValue = "Ready to Install"
        subtitleLabel.stringValue = "Pulse will relaunch to finish updating"
        notesCard.isHidden = true
        progressWrap.isHidden = false
        let trackW = max(1, progressTrack.bounds.width > 0 ? progressTrack.bounds.width : 408)
        progressFillWidth.constant = trackW
        progressLabel.stringValue = "Download verified ✓"
        secondaryBtn.isHidden = false
        secondaryBtn.title = "Later"
        primaryBtn.isHidden = false
        primaryBtn.title = "Restart & Update"
        resize(height: 176)
        present()
    }

    func showInstalling() {
        clearCallbacks()
        titleLabel.stringValue = "Installing Update…"
        subtitleLabel.stringValue = "Pulse will reopen in a moment"
        secondaryBtn.isHidden = true
        primaryBtn.isHidden = true
        progressLabel.stringValue = "Applying update…"
    }

    func showError(_ message: String, acknowledgement: @escaping () -> Void) {
        clearCallbacks()
        errorAck = acknowledgement
        titleLabel.stringValue = "Update Couldn't Complete"
        subtitleLabel.stringValue = "Your current version is unchanged"
        notesCard.isHidden = false
        progressWrap.isHidden = true
        setNotesPlain(message)
        secondaryBtn.isHidden = true
        primaryBtn.isHidden = false
        primaryBtn.title = "OK"
        resize(height: 230)
        present()
    }

    func dismiss() {
        clearCallbacks()
        isProgrammaticClose = true
        window.orderOut(nil)
        isProgrammaticClose = false
    }

    @objc private func onPrimary() {
        if let cb = updateReply {
            clearCallbacks()
            cb(.install)
        } else if let cb = readyReply {
            clearCallbacks()
            cb(.install)
        } else if let cb = permReply {
            clearCallbacks()
            cb(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
            dismiss()
        } else if let cb = errorAck {
            clearCallbacks()
            cb()
            dismiss()
        }
    }

    @objc private func onSecondary() {
        if let cb = checkCancel {
            clearCallbacks()
            cb()
            dismiss()
        } else if let cb = downloadCancel {
            clearCallbacks()
            cb()
            dismiss()
        } else if let cb = updateReply {
            clearCallbacks()
            cb(.dismiss)
            dismiss()
        } else if let cb = readyReply {
            clearCallbacks()
            cb(.dismiss)
            dismiss()
        } else if let cb = permReply {
            clearCallbacks()
            cb(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
            dismiss()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if isProgrammaticClose { return }
        if let cb = checkCancel { clearCallbacks(); cb() }
        else if let cb = downloadCancel { clearCallbacks(); cb() }
        else if let cb = updateReply { clearCallbacks(); cb(.dismiss) }
        else if let cb = readyReply { clearCallbacks(); cb(.dismiss) }
        else if let cb = permReply { clearCallbacks(); cb(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)) }
        else if let cb = errorAck { clearCallbacks(); cb() }
    }
}

/// Custom Sparkle user driver backed by `PulseUpdateWindowController` so every
/// update prompt, progress bar, and error matches Pulse's dark card UI — and
/// "no newer version" stays silent in favor of the dashboard's Updates card.
@MainActor
final class QuietUserDriver: NSObject, SPUUserDriver {
    private unowned let shell: Shell
    private lazy var ui = PulseUpdateWindowController()

    init(shell: Shell) {
        self.shell = shell
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let raw = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let reason = raw.map { SPUNoUpdateFoundReason(rawValue: OSStatus($0.intValue)) }
        if reason == .onLatestVersion || reason == .onNewerThanLatestVersion {
            shell.updateCheckFoundNothing()
            ui.dismiss()
            acknowledgement()
        } else {
            shell.updateCheckFailed()
            ui.showError(error.localizedDescription, acknowledgement: acknowledgement)
        }
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        ui.showPermission(request, reply: reply)
    }

    /// Skip the checking window when started from the dashboard's Updates card
    /// (the card animates its own inline progress bar).
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if shell.checkFromWeb { return }
        ui.showChecking(cancellation: cancellation)
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ui.showUpdateFound(item: item, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        ui.showReleaseNotes(downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Keep the inline appcast description or fallback message already shown.
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        ui.showError(error.localizedDescription, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        ui.showDownloadStarted(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        ui.setExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        ui.addReceivedBytes(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        ui.showExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        ui.setExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ui.showReady(reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated terminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        ui.showInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        ui.dismiss()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        ui.dismiss()
    }

    func showUpdateInFocus() {
        ui.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Dev-only screen gallery (enabled only when `PULSE_PREVIEW=1` is set).
/// Lets you inspect every native window, splash, alert, and update state on demand.
@MainActor
final class PulsePreviewController: NSObject {
    private unowned let shell: Shell
    private let window: NSWindow
    private lazy var updateUI = PulseUpdateWindowController()
    private var splashVisible = false
    private var simulatedUpdateOn = false

    private let panelBg = NSColor(red: 0.071, green: 0.082, blue: 0.114, alpha: 1)  // #12151d
    private let cardBg = NSColor(red: 0.090, green: 0.106, blue: 0.145, alpha: 1)   // #171b25
    private let borderCol = NSColor(red: 0.137, green: 0.165, blue: 0.220, alpha: 1) // #232a38
    private let textCol = NSColor(red: 0.910, green: 0.925, blue: 0.957, alpha: 1)   // #e8ecf4
    private let dimCol = NSColor(red: 0.545, green: 0.580, blue: 0.655, alpha: 1)    // #8b94a7
    private let faintCol = NSColor(red: 0.353, green: 0.388, blue: 0.459, alpha: 1)  // #5a6375
    private let accentOrange = NSColor(red: 1.0, green: 0.624, blue: 0.263, alpha: 1) // #ff9f43

    init(shell: Shell) {
        self.shell = shell
        window = NSWindow(
            contentRect: NSRect(x: 40, y: 180, width: 256, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = panelBg
        window.isReleasedWhenClosed = false
        super.init()
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = panelBg.cgColor
        window.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let title = NSTextField(labelWithString: "Screen Gallery")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.textColor = textCol
        let sub = NSTextField(labelWithString: "Dev preview (PULSE_PREVIEW=1)")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = accentOrange
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(2, after: title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(10, after: sub)

        let addSec = { (label: String) in
            let l = NSTextField(labelWithString: label.uppercased())
            l.font = .systemFont(ofSize: 9.5, weight: .bold)
            l.textColor = self.faintCol
            stack.addArrangedSubview(l)
        }
        let addBtn = { (label: String, action: Selector) in
            let b = NSButton(title: label, target: self, action: action)
            b.isBordered = false
            b.wantsLayer = true
            b.font = .systemFont(ofSize: 11.5, weight: .medium)
            b.alignment = .left
            b.contentTintColor = self.textCol
            b.layer?.backgroundColor = self.cardBg.cgColor
            b.layer?.borderColor = self.borderCol.cgColor
            b.layer?.borderWidth = 1
            b.layer?.cornerRadius = 7
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        addSec("App & Settings")
        addBtn("  Toggle Launch Splash", #selector(pSplash))
        addBtn("  About Pulse", #selector(pAbout))
        addBtn("  Web Settings Modal", #selector(pWebSettings))
        addBtn("  Native Settings Window", #selector(pNativeSettings))

        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)
        addSec("Update Dialogs")
        addBtn("  Update: Checking…", #selector(pUpdCheck))
        addBtn("  Update: Available (v1.6)", #selector(pUpdAvail))
        addBtn("  Update: Downloading (64%)", #selector(pUpdDown))
        addBtn("  Update: Extracting (45%)", #selector(pUpdExt))
        addBtn("  Update: Ready to Install", #selector(pUpdReady))
        addBtn("  Update: Error", #selector(pUpdErr))
        addBtn("  Update: Permission", #selector(pUpdPerm))

        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)
        addSec("Chrome & Alerts")
        addBtn("  Toggle Pending Update Strip", #selector(pPendingStrip))
        addBtn("  Dark Confirm Alert", #selector(pConfirmAlert))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
        ])
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func pSplash() {
        splashVisible.toggle()
        shell.launchSplash?.isHidden = !splashVisible
        shell.web?.isHidden = splashVisible
        shell.window.makeKeyAndOrderFront(nil)
    }

    @objc private func pAbout() { shell.openAbout() }
    @objc private func pWebSettings() {
        splashVisible = false
        shell.launchSplash?.isHidden = true
        shell.web?.isHidden = false
        shell.openSettings()
    }
    @objc private func pNativeSettings() { shell.openNativeSettings() }

    @objc private func pUpdCheck() {
        updateUI.showChecking { [weak self] in self?.updateUI.dismiss() }
    }
    @objc private func pUpdAvail() {
        let html = """
        <p><b>What's New in Pulse 1.6</b></p>
        <ul>
          <li>Redesigned macOS squircle icon, DMG installer window, and native launch splash.</li>
          <li>Pulse-styled dark update dialogs and About window.</li>
          <li>Live menu-bar capsule preview inside Settings.</li>
        </ul>
        """
        updateUI.showPreviewAvailable(version: "1.6", sizeBytes: 2_480_000, htmlNotes: html)
    }
    @objc private func pUpdDown() {
        updateUI.showDownloadStarted { [weak self] in self?.updateUI.dismiss() }
        updateUI.setExpectedLength(2_480_000)
        updateUI.addReceivedBytes(1_587_200)
    }
    @objc private func pUpdExt() {
        updateUI.showDownloadStarted {}
        updateUI.showExtracting()
        updateUI.setExtractionProgress(0.45)
    }
    @objc private func pUpdReady() {
        updateUI.showReady { [weak self] _ in self?.updateUI.dismiss() }
    }
    @objc private func pUpdErr() {
        updateUI.showError("Could not reach GitHub Releases (request timed out after 15s).") {}
    }
    @objc private func pUpdPerm() {
        updateUI.showPreviewPermission()
    }
    @objc private func pPendingStrip() {
        simulatedUpdateOn.toggle()
        shell.pendingUpdateVersion = simulatedUpdateOn ? "1.6" : nil
        shell.setUpdateIndicators()
    }
    @objc private func pConfirmAlert() {
        let a = NSAlert()
        a.window.appearance = NSAppearance(named: .darkAqua)
        a.messageText = "Pulse"
        a.informativeText = "Force quit Google Chrome (PID 4182)?"
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.runModal()
    }
}

final class Shell: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, SPUUpdaterDelegate {
    var window: NSWindow!
    var web: WKWebView?
    var settings = PulseSettings()
    var settingsController: SettingsWindowController?
    var nodeProc: Process?
    var retiredProcs: [Process] = []
    var spawnedNode = false
    var isRacingDaemon = false
    var daemonAttachGen = 0
    var restartingBackend = false
    var switchingBackend = false
    var lastBackendMtime: Int?
    var quitting = false
    var loaded = false
    var pageLoaded = false
    var injectedBackendUrl: String?
    var serverPort: Int?
    var selfTestScheduled = false
    var status: StatusController?
    var updater: SPUUpdater!
    var updateDriver: QuietUserDriver!   // retained here — the updater may only reference it
    var pendingUpdateVersion: String?   // newest appcast version not yet installed
    var lastCheckAtMs: Int?             // epoch ms of the last completed check that found nothing
    var lastFailedAtMs: Int?            // epoch ms of the last failed check — backs the card's “· tried <age>”
    var updateChecking = false          // a check is in flight — drives the “Checking…” states
    var lastCheckFailed = false         // the last check errored — “couldn't check” ≠ “up to date"
    var checkFromWeb = false            // the in-flight check was initiated from the dashboard card
    var checkSafetyTimer: Timer?        // a canceled/dropped check never gets a result callback
    let updateStrip = UpdateStripView()
    var webTopToWindowAnchor: NSLayoutConstraint?   // webview top ↔ content-view top (strip hidden)
    var webTopToStripAnchor: NSLayoutConstraint?   // webview top ↔ strip bottom (strip visible)
    var launchSplash: NSView?
    var activityToken: NSObjectProtocol?
    let darkBg = NSColor(srgbRed: 0x0b / 255.0, green: 0x0d / 255.0, blue: 0x12 / 255.0, alpha: 1)

    @objc func reload() {
        if spawnedNode, let disk = expectedServerMtime(), disk != lastBackendMtime {
            restartSpawnedBackend()
        } else {
            loadDashboard(port: serverPort)
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
        let cv = window.contentView!
        let w = WKWebView(frame: cv.bounds, configuration: cfg)
        w.translatesAutoresizingMaskIntoConstraints = false
        // Two top edges, exactly one active at a time (toggled in syncUpdateStrip):
        // flush with the window top while the strip is hidden, or below the strip
        // while it's visible — the dashboard must never end up underneath it.
        // The constraints are only *activated* once `w` has a superview (below):
        // activating a constraint whose items don't share a hierarchy throws.
        webTopToWindowAnchor = NSLayoutConstraint(item: w, attribute: .top, relatedBy: .equal,
                                                  toItem: cv, attribute: .top, multiplier: 1, constant: 0)
        webTopToStripAnchor = NSLayoutConstraint(item: w, attribute: .top, relatedBy: .equal,
                                                 toItem: updateStrip, attribute: .bottom, multiplier: 1, constant: 0)
        w.navigationDelegate = self
        w.uiDelegate = self
        // Stop WebKit from drawing an opaque white backing before HTML commits, and keep the
        // webview hidden over the dark AppKit splash until `skeleton_paint` fires.
        w.setValue(false, forKey: "drawsBackground")
        w.isHidden = true
        w.wantsLayer = true
        w.layer?.backgroundColor = darkBg.cgColor
        if #available(macOS 12.0, *) {
            w.underPageBackgroundColor = darkBg
        }
        cv.addSubview(w, positioned: .below, relativeTo: updateStrip.superview === cv ? updateStrip : nil)
        // Superview first: activating constraints whose items don't share a hierarchy
        // throws. The top edge is pinned by syncUpdateStrip, which anchors the strip
        // itself when needed and then selects the webview's top constraint.
        NSLayoutConstraint.activate([
            w.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            w.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            w.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
        web = w
        syncUpdateStrip()
        return w
    }

    func revealWebView() {
        web?.isHidden = false
        launchSplash?.isHidden = true
    }

    func releaseWebView() {
        guard let w = web else { return }
        w.stopLoading()
        w.configuration.userContentController.removeScriptMessageHandler(forName: "pulseTrace")
        w.configuration.userContentController.removeScriptMessageHandler(forName: "pulseSettings")
        w.navigationDelegate = nil
        w.uiDelegate = nil
        w.removeFromSuperview()
        launchSplash?.isHidden = false
        syncUpdateStrip()
        web = nil
        loaded = false
        pageLoaded = false
        injectedBackendUrl = nil
    }

    private func retireProc(_ proc: Process, delay: TimeInterval = 0) {
        retiredProcs.append(proc)
        let stop = { [weak self] in
            if proc.isRunning { proc.terminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self?.retiredProcs.removeAll { $0 === proc }
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: stop)
        } else {
            stop()
        }
    }

    func loadDashboard(port: Int?) {
        let w = ensureWebView()
        w.isHidden = true
        launchSplash?.isHidden = false
        loaded = true
        pageLoaded = false
        let (htmlPath, publicDir) = uiSourcePath()
        var comp = URLComponents(url: URL(fileURLWithPath: htmlPath), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "r", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        if let port {
            let backendUrl = "http://\(host):\(port)"
            items.append(URLQueryItem(name: "backend", value: backendUrl))
            injectedBackendUrl = backendUrl
        } else {
            injectedBackendUrl = nil
        }
        comp.queryItems = items
        BootTracer.shared.mark("webview_load")
        if let fileUrl = comp.url {
            w.loadFileURL(fileUrl, allowingReadAccessTo: URL(fileURLWithPath: publicDir, isDirectory: true))
        } else if let port {
            w.load(URLRequest(url: urlForPort(port, "/?r=\(Int(Date().timeIntervalSince1970 * 1000))")))
        }
    }

    func syncBackendToWeb(onWake: (() -> Void)? = nil) {
        guard let w = web, pageLoaded, let port = serverPort else { return }
        let target = "http://\(host):\(port)"
        if injectedBackendUrl == target {
            w.evaluateJavaScript("window.__pulseWake && window.__pulseWake(); true") { _, _ in onWake?() }
            return
        }
        injectedBackendUrl = target
        let js = "window.__pulseSetBackend && window.__pulseSetBackend(\"\(target)\"); true"
        w.evaluateJavaScript(js) { _, _ in onWake?() }
    }

    @objc func openApp() {
        let wasHidden = !window.isVisible
        let hadWarmWeb = (web != nil && pageLoaded)
        if wasHidden {
            BootTracer.shared.beginSession(mode: "reopen", extra: "warm_webview=\(hadWarmWeb)")
            BootTracer.shared.mark("window_reopen")
        }
        _ = ensureWebView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !loaded {
            loadDashboard(port: serverPort)
        } else if hadWarmWeb {
            syncBackendToWeb {
                if wasHidden { BootTracer.shared.mark("first_render", once: true) }
            }
        }
    }

    private var aboutController: PulseAboutWindowController?
    private var previewController: PulsePreviewController?

    @objc func openAbout() {
        if aboutController == nil {
            aboutController = PulseAboutWindowController(shell: self)
        }
        aboutController?.show()
    }

    @objc func openSettings() {
        if window.isVisible, let w = web, pageLoaded {
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
        guard let w = web, pageLoaded,
              let data = try? JSONSerialization.data(withJSONObject: currentSettingsPayload()),
              let json = String(data: data, encoding: .utf8) else { return }
        w.evaluateJavaScript("window.__pulseSyncSettings && window.__pulseSyncSettings(\(json)); true", completionHandler: nil)
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
        isRacingDaemon = false
        daemonAttachGen += 1
        let gen = daemonAttachGen
        settings.mergeFromDisk()
        settings.startAtLogin = enabled
        settings.save()
        syncAllSettingsUI()

        if enabled {
            findNodeAsync { [weak self] node in
                guard let self, gen == self.daemonAttachGen else { return }
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
                    try? FileManager.default.removeItem(atPath: portFilePath())
                    if p.isRunning { p.terminate() }
                }
                mgr.workQueue.async { [weak self] in
                    if let dp = dyingProc {
                        let deadline = Date().addingTimeInterval(0.25)
                        while dp.isRunning && Date() < deadline { usleep(15_000) }
                    }
                    let result = mgr.installAndBootstrap(nodePath: node)
                    DispatchQueue.main.async {
                        guard let self, gen == self.daemonAttachGen else { return }
                        mgr.isTransitioning = false
                        switch result {
                        case .success:
                            self.settings.startAtLogin = true
                            self.settings.save()
                            self.syncAllSettingsUI()
                            self.attachToDaemonPort(attemptsLeft: 25, gen: gen)
                        case .failure:
                            try? FileManager.default.removeItem(atPath: pulseDir + "/preferred-port")
                            self.switchingBackend = false
                            self.settings.startAtLogin = false
                            self.settings.save()
                            self.syncAllSettingsUI()
                            if self.serverPort == nil || !self.spawnedNode {
                                self.spawnBackend(portOverride: oldPort, nodePath: node, isRace: false)
                            }
                        }
                    }
                }
            }
        } else {
            let wasDaemonOwned = !spawnedNode
            let oldPort = serverPort
            if wasDaemonOwned {
                try? FileManager.default.removeItem(atPath: portFilePath())
            }
            mgr.workQueue.async { [weak self] in
                _ = mgr.uninstall()
                DispatchQueue.main.async {
                    guard let self, gen == self.daemonAttachGen else { return }
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

    private func attachToDaemonPort(attemptsLeft: Int, gen: Int) {
        guard gen == daemonAttachGen, !quitting else { return }
        if let info = readPortFileInfo() {
            // Skip stale/unowned or self-racer port entries without burning a probe attempt.
            let isRacerPid = (spawnedNode && nodeProc.map { info.pid == $0.processIdentifier } ?? false)
            if !isRacerPid && (info.pid == nil || isProcessAlive(info.pid!)) {
                BootTracer.shared.mark("port_file_seen", once: true, launchOnly: true)
                checkServerAlive(port: info.port, timeout: 0.6) { [weak self] alive in
                    guard let self, !self.quitting, gen == self.daemonAttachGen else { return }
                    if alive {
                        BootTracer.shared.mark("backend_alive", once: true, launchOnly: true)
                        let wasRacing = self.isRacingDaemon
                        self.switchingBackend = false
                        self.isRacingDaemon = false
                        var racerToStop: Process?
                        if self.spawnedNode, self.serverPort != info.port, let dying = self.nodeProc {
                            self.nodeProc = nil
                            self.spawnedNode = false
                            racerToStop = dying
                        }
                        self.serverPort = info.port
                        self.spawnedNode = false
                        if wasRacing {
                            BootTracer.shared.mark("daemon_migrated", once: true, launchOnly: true)
                        }
                        self.status?.start(port: info.port)
                        self.syncAllSettingsUI()
                        if self.window.isVisible {
                            if self.loaded {
                                self.syncBackendToWeb()
                            } else {
                                self.loadDashboard(port: info.port)
                            }
                        }
                        if let dying = racerToStop {
                            self.retireProc(dying, delay: 0.2)
                        }
                        return
                    }
                    if attemptsLeft > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            self.attachToDaemonPort(attemptsLeft: attemptsLeft - 1, gen: gen)
                        }
                    } else {
                        self.promoteOrSpawnFallback()
                    }
                }
                return
            }
        }
        if attemptsLeft > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.attachToDaemonPort(attemptsLeft: attemptsLeft - 1, gen: gen)
            }
        } else {
            promoteOrSpawnFallback()
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
        startUpdateCheck(fromWeb: false)
    }

    /// Starts a Sparkle appcast check. `fromWeb` records which UI initiated it:
    /// a check from the dashboard's Updates card reports progress on the card's own
    /// progress bar, so the stock progress window is suppressed (it flashed open and
    /// closed faster than it could be read on a fast appcast fetch — see
    /// QuietUserDriver). Checks started from the menu, strip or the Settings window
    /// keep the stock window as their feedback. (Deliberately not named like
    /// `checkForUpdates` — the `#selector` menu wiring must stay unambiguous.)
    func startUpdateCheck(fromWeb: Bool) {
        guard !updateChecking else { return }
        updateChecking = true
        checkFromWeb = fromWeb
        setUpdateIndicators()
        // Sparkle has no delegate callback for a *canceled* check, so a canceled
        // or dropped check would otherwise leave the in-flight states (and every
        // surface's “Checking…” UI) stuck. By the time this fires the appcast
        // fetch timeout (~60s) has long passed — a real check always completed.
        checkSafetyTimer?.invalidate()
        checkSafetyTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            guard let self, self.updateChecking else { return }
            self.updateChecking = false
            self.checkFromWeb = false
            self.setUpdateIndicators()   // sync without a result — the card goes back to neutral
        }
        updater.checkForUpdates()
    }

    /// Anchor the strip to the top edge of whatever the current content view is, and
    /// pin the webview's top edge *below* the strip while it's visible — the strip must
    /// never cover the dashboard (the page reflows around it instead). The webview is
    /// released and re-created when the dashboard closes/reopens, so this is re-asserted
    /// on every (re)creation and on every update-state change. Idempotent.
    func syncUpdateStrip() {
        guard let cv = window.contentView else { return }
        if updateStrip.superview !== cv {
            updateStrip.removeFromSuperview()
            // Deactivate only constraints owned solely by the strip itself (e.g. its
            // height anchor); subview constraints (labelField centering) also live in
            // `updateStrip.constraints` and must remain active across re-anchoring.
            for c in updateStrip.constraints where c.firstItem === updateStrip && c.secondItem == nil {
                c.isActive = false
            }
            cv.addSubview(updateStrip, positioned: .above, relativeTo: nil)
            updateStrip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                updateStrip.topAnchor.constraint(equalTo: cv.topAnchor),
                updateStrip.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                updateStrip.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                updateStrip.heightAnchor.constraint(equalToConstant: UpdateStripView.height),
            ])
        }
        guard let w = web, w.superview === cv,
              let toWindow = webTopToWindowAnchor, let toStrip = webTopToStripAnchor else { return }
        // The strip's own anchor was ensured above; while it's visible the webview
        // hangs off the strip's bottom edge, otherwise it's flush with the window top.
        if updateStrip.isHidden {
            toStrip.isActive = false
            toWindow.isActive = true
        } else {
            toWindow.isActive = false
            toStrip.isActive = true
        }
    }

    // MARK: Update helpers

    /// True when version `a` is strictly newer than `b`.
    /// Bases are compared numerically ("1.10" > "1.9"). When the bases are
    /// equal, only a plain version counts as newer than a suffixed one (a final
    /// release supersedes its dev build) — "1.4" vs "1.4" is the same version,
    /// not an update. This is what stops stale "Update available" states for
    /// builds whose version was bumped ahead of the release.
    private func isNewerVersion(_ a: String, _ b: String) -> Bool {
        let baseA = a.split(separator: "-").first.map(String.init) ?? a
        let baseB = b.split(separator: "-").first.map(String.init) ?? b
        if baseA == baseB {
            return !a.contains("-") && b.contains("-")
        }
        return baseA.compare(baseB, options: .numeric) == .orderedDescending
    }

    /// Reflect the update state on every surface: the thin top strip, the status-menu row,
    /// the native Settings card, and the dashboard. `pendingUpdateVersion` is only
    /// ever set to genuinely newer versions (guarded in `didFindValidUpdate`), so it
    /// can be read directly here.
    func setUpdateIndicators() {
        let v = pendingUpdateVersion
        updateStrip.setVersion(v)
        syncUpdateStrip()
        status?.showUpdateRow(v)
        settingsController?.syncFromState()
        pushUpdateToWeb()
    }

    func pushUpdateToWeb() {
        guard let w = web, pageLoaded else { return }
        let current = (Bundle.main.object(forInfoDictionaryKey:
            "CFBundleShortVersionString") as? String) ?? "1.0"
        // `current` always rides along — the "up to date" card shows it too.
        // `checking` drives the card's inline progress bar while a check is in
        // flight; `failed` lets it say "couldn't check" instead of claiming
        // "up to date" (with `failedAt` — epoch ms of the failed attempt —
        // backing the “· tried <age>” suffix); `checkedAt` backs the “· checked
        // just now” confirmation.
        var payload: [String: Any] = ["current": current, "checking": updateChecking]
        if let available = pendingUpdateVersion {
            payload["available"] = available
        }
        if let checkedAt = lastCheckAtMs {
            payload["checkedAt"] = checkedAt
        }
        if lastCheckFailed {
            payload["failed"] = true
            if let failedAt = lastFailedAtMs {
                payload["failedAt"] = failedAt
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        w.evaluateJavaScript("window.__pulseUpdate && window.__pulseUpdate(\(json))", completionHandler: nil)
    }

    /// Final feedback for a check that completed with nothing to install: clears
    /// the in-flight/failed states, stamps the check time, and re-renders every
    /// surface. The dashboard's Updates card turns this into its inline “up to
    /// date · checked just now” confirmation (which replaced the stock modal alert).
    func updateCheckFoundNothing() {
        checkSafetyTimer?.invalidate()
        updateChecking = false
        checkFromWeb = false
        lastCheckFailed = false
        lastFailedAtMs = nil            // a completed check supersedes any earlier failure
        lastCheckAtMs = Int(Date().timeIntervalSince1970 * 1000)
        setUpdateIndicators()
        selfTestCheckCompleted()
    }

    /// A check that failed (the appcast fetch or parse couldn't complete — e.g.
    /// the network): availability keeps its previous state — a failed check is
    /// not “up to date” — but every surface learns the check itself errored so
    /// the card stops claiming “up to date”.
    func updateCheckFailed() {
        checkSafetyTimer?.invalidate()
        updateChecking = false
        checkFromWeb = false
        lastCheckFailed = true
        lastFailedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        setUpdateIndicators()
        selfTestCheckCompleted()
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
        checkSafetyTimer?.invalidate()
        updateChecking = false
        checkFromWeb = false
        lastCheckFailed = false
        // Guard at the source: Sparkle can call this even when the appcast entry equals
        // the installed version (e.g. a dev build whose marketing version was already
        // bumped for a release, but whose build number wasn't). Never advertise a
        // version that isn't actually newer — this makes `pendingUpdateVersion`
        // trustworthy for every consumer (strip, menu, Settings, web UI).
        let available = item.displayVersionString
        let current = (Bundle.main.object(forInfoDictionaryKey:
            "CFBundleShortVersionString") as? String) ?? "1.0"
        pendingUpdateVersion = isNewerVersion(available, current) ? available : nil
        setUpdateIndicators()
        selfTestCheckCompleted()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        pendingUpdateVersion = nil
        // Dormant fallback: Sparkle only calls the no-argument variant when the
        // error variant (below) isn't implemented — it is, so the classification
        // lives there. Kept as a safe default: a “no update” outcome means the
        // check completed.
        // Covers launch, scheduled and manual checks alike: any completed check that
        // found nothing stamps `lastCheckAtMs` so the card's “· checked <age>” is true.
        updateCheckFoundNothing()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Sparkle routes *every* “no update” outcome through here — including the
        // routine one, where the user is already on the latest version: the error
        // is a SUNoUpdateError pseudo-error, not a failure (see SPUNoUpdateFoundReason
        // in the userInfo). A check that fetched the feed fine and found nothing to
        // install must land as a *success* — a failed fetch never reaches this method
        // (it aborts earlier, see `updater(_:didAbortWithError:)`), so classifying
        // the whole callback as a failure is what made every successful hourly check
        // flip the card to “couldn't check for updates”.
        let e = error as NSError
        if e.domain == SUSparkleErrorDomain, e.code == Int(SUError.noUpdateError.rawValue) {
            pendingUpdateVersion = nil
            updateCheckFoundNothing()
        } else {
            updateCheckFailed()
        }
    }

    /// The update cycle aborted for a real reason — the appcast fetch or parse
    /// failed, a download died, …: the one delegate signal for checks that never
    /// completed, so this is what marks the check failed. The benign aborts are
    /// skipped: SUNoUpdateError is the up-to-date outcome (already resolved in
    /// `updaterDidNotFindUpdate(_:error:)`) and the installation cancel/postpone
    /// codes are user actions on an update, not check failures.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let e = error as NSError
        if e.domain == SUSparkleErrorDomain,
           let code = SUError(rawValue: OSStatus(e.code)),
           code == .noUpdateError || code == .installationCanceledError || code == .installationAuthorizeLaterError {
            return
        }
        updateCheckFailed()
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
            let allowed: Set<String> = ["dom_content_loaded", "skeleton_paint", "first_sse_message", "first_render"]
            guard allowed.contains(stage) else { return }
            let ts = (body["t"] as? NSNumber)?.int64Value
            BootTracer.shared.mark(stage, tsOverrideMs: ts, once: true)
            if stage == "skeleton_paint" {
                revealWebView()
            }
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
                startUpdateCheck(fromWeb: true)
                if isSelfTest { armSelfTestCheckFlow() }
            case "revealInFinder":
                guard let p = body["path"] as? String, p.hasPrefix("/"), !p.contains("\0"),
                      FileManager.default.fileExists(atPath: p) else { break }
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
            case "copyText":
                guard let text = body["text"] as? String, !text.isEmpty else { break }
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 940, height: 620)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = darkBg
        let rootView = NSView(frame: rect)
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = darkBg.cgColor
        window.contentView = rootView

        // Immediate AppKit splash shown inside rootView until WebKit paints `skeleton_paint`.
        let splash = NSStackView()
        splash.orientation = .vertical
        splash.alignment = .centerX
        splash.spacing = 10
        splash.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),
        ])

        let wordmark = NSTextField(labelWithString: "Pulse")
        wordmark.font = .systemFont(ofSize: 22, weight: .bold)
        wordmark.textColor = NSColor(srgbRed: 0xe8 / 255.0, green: 0xec / 255.0, blue: 0xf4 / 255.0, alpha: 0.94)

        let subtitle = NSTextField(labelWithString: "Mac Resource Monitor")
        subtitle.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.textColor = NSColor(srgbRed: 0x8b / 255.0, green: 0x94 / 255.0, blue: 0xa7 / 255.0, alpha: 0.85)

        splash.addArrangedSubview(iconView)
        splash.addArrangedSubview(wordmark)
        splash.setCustomSpacing(4, after: wordmark)
        splash.addArrangedSubview(subtitle)
        rootView.addSubview(splash)
        NSLayoutConstraint.activate([
            splash.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            splash.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
        ])
        launchSplash = splash

        // Update strip along the top edge — the quiet, persistent “an update is
        // available, click to install” indicator (hidden until one is). syncUpdateStrip
        // owns its constraints (and the webview's top edge while it's visible).
        updateStrip.setVersion(nil)
        updateStrip.translatesAutoresizingMaskIntoConstraints = false
        updateStrip.onClick = { [weak self] in self?.checkForUpdates() }

        // Kick off backend discovery / spawn immediately so it runs in parallel with
        // WKWebView, menu bar, and Sparkle initialization on the main thread.
        status = StatusController(shell: self)
        status?.localLayoutGen = settings.layoutGen
        status?.onStaleBackend = { [weak self] in self?.handleStaleBackend() }
        startServer()

        _ = ensureWebView()
        BootTracer.shared.mark("webview_ready", once: true, launchOnly: true)

        // Main menu: App (About, Settings Cmd-,, Updates, Quit Cmd-Q), Edit (Copy/Paste/Find), View (Reload), Window (Close Cmd-W).
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Pulse", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
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

        if !loaded {
            loadDashboard(port: serverPort)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // A raw SPUUpdater with Pulse's own user driver: the stock driver handles
        // everything except the dead-end “you're up to date” modal, which the
        // dashboard's Updates card confirms inline (see QuietUserDriver).
        updateDriver = QuietUserDriver(shell: self)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updateDriver, delegate: self)
        do { try updater.start() } catch { NSLog("Pulse updater failed to start: \(error)") }

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

        if ProcessInfo.processInfo.environment["PULSE_PREVIEW"] == "1" {
            previewController = PulsePreviewController(shell: self)
            previewController?.show()
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
        if let info = readPortFileInfo() {
            if let pid = info.pid, !isProcessAlive(pid) {
                if agent.plistExists {
                    refreshDaemonOrSpawn()
                } else {
                    spawnBackend(portOverride: nil)
                }
                return
            }
            BootTracer.shared.mark("port_probe_start")
            checkServerAlive(port: info.port, timeout: 1.0) { [weak self] alive in
                guard let self else { return }
                if alive {
                    BootTracer.shared.mark("daemon_reused")
                    self.serverPort = info.port
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
        daemonAttachGen += 1
        let gen = daemonAttachGen
        switchingBackend = true
        findNodeAsync { [weak self] node in
            guard let self, !self.quitting, gen == self.daemonAttachGen else { return }
            guard let node else {
                self.switchingBackend = false
                self.spawnBackend(portOverride: nil)
                return
            }
            // Launch a direct racer in parallel with LaunchAgent bootstrap/kickstart
            // (~300ms first snapshot vs ~2.5s under Background QoS), then swap live.
            if !self.spawnedNode {
                BootTracer.shared.mark("race_start", once: true, launchOnly: true)
                self.isRacingDaemon = true
                self.spawnBackend(portOverride: nil, nodePath: node, isRace: true)
            }
            let agent = LaunchAgentManager.shared
            agent.workQueue.async { [weak self] in
                let needsInstall = agent.needsPlistRefresh(nodePath: node) || !agent.isLoaded()
                if needsInstall {
                    BootTracer.shared.mark("bootstrap_call", once: true, launchOnly: true)
                    let res = agent.installAndBootstrap(nodePath: node)
                    BootTracer.shared.mark("bootstrap_done", once: true, launchOnly: true)
                    DispatchQueue.main.async {
                        guard let self, !self.quitting, gen == self.daemonAttachGen else { return }
                        switch res {
                        case .success:
                            self.attachToDaemonPort(attemptsLeft: 40, gen: gen)
                        case .failure:
                            self.promoteOrSpawnFallback(nodePath: node)
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
                        BootTracer.shared.mark("kickstart_call", once: true, launchOnly: true)
                        kicked = agent.kickstart()
                        BootTracer.shared.mark("kickstart_done", once: true, launchOnly: true)
                    }
                    DispatchQueue.main.async {
                        guard let self, !self.quitting, gen == self.daemonAttachGen else { return }
                        self.attachToDaemonPort(attemptsLeft: kicked ? 40 : 30, gen: gen)
                    }
                }
            }
        }
    }

    private func promoteOrSpawnFallback(nodePath: String? = nil) {
        switchingBackend = false
        if isRacingDaemon, spawnedNode, let port = serverPort, let proc = nodeProc, proc.isRunning {
            isRacingDaemon = false
            // If launchd finishes binding after the 40-attempt (~4.8s) attach window,
            // it leaves a second sampler running for this session and self-heals on next
            // launch/toggle via the pid-owned port file.
            writePortFileIfUnowned(port: port, pid: proc.processIdentifier)
            return
        }
        isRacingDaemon = false
        spawnBackend(portOverride: nil, nodePath: nodePath, isRace: false)
    }

    func handleStaleBackend() {
        guard !quitting, !switchingBackend else { return }
        if spawnedNode {
            restartSpawnedBackend()
        } else if LaunchAgentManager.shared.plistExists {
            refreshDaemonOrSpawn()
        } else {
            spawnBackend(portOverride: nil)
        }
    }

    func restartSpawnedBackend() {
        guard spawnedNode, !quitting, !restartingBackend else { return }
        restartingBackend = true
        if let old = nodeProc {
            nodeProc = nil
            retireProc(old)
        }
        serverPort = nil
        injectedBackendUrl = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.quitting else { return }
            self.restartingBackend = false
            self.spawnBackend(portOverride: nil)
        }
    }

    func spawnBackend(portOverride: Int?, nodePath: String? = nil, isRace: Bool = false) {
        BootTracer.shared.mark("backend_spawn")
        let startWithNode: (String?) -> Void = { [weak self] node in
            guard let self, !self.quitting else { return }
            if isRace && !self.isRacingDaemon { return }
            guard let node else {
                self.switchingBackend = false
                self.isRacingDaemon = false
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
            if isSelfTest {
                env["PULSE_PORT_FILE"] = portFilePath()
            }
            if isRace {
                env["PULSE_RACE"] = "1"
            }
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
                    if isRace && self.isRacingDaemon {
                        self.nodeProc = nil
                        self.spawnedNode = false
                        self.isRacingDaemon = false
                        return
                    }
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
                if !isRace {
                    self.showFatal("Could not start the Pulse backend:\n\(error.localizedDescription)")
                } else {
                    self.isRacingDaemon = false
                }
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
                                guard let self, !self.quitting, p === self.nodeProc else { return }
                                BootTracer.shared.mark("pulse_listening", once: true)
                                if isRace {
                                    BootTracer.shared.mark("race_backend_ready", once: true, launchOnly: true)
                                } else {
                                    self.switchingBackend = false
                                }
                                let target = "http://\(host):\(port)"
                                let samePortAndLoaded = (self.serverPort == port && self.loaded && self.injectedBackendUrl == target)
                                self.serverPort = port
                                if samePortAndLoaded {
                                    self.status?.start(port: port)
                                    self.syncAllSettingsUI()
                                    if self.window.isVisible {
                                        self.syncBackendToWeb()
                                    }
                                } else {
                                    self.beginService()
                                }
                            }
                        }
                    }
                }
            }
        }
        if let nodePath {
            startWithNode(nodePath)
        } else {
            findNodeAsync(completion: startWithNode)
        }
    }

    func beginService() {
        guard let port = serverPort else { return }
        status?.start(port: port)
        syncAllSettingsUI()
        if window.isVisible {
            if loaded {
                syncBackendToWeb()
            } else {
                loadDashboard(port: port)
            }
        }
        if isSelfTest && !selfTestScheduled {
            selfTestScheduled = true
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
        // NOTE: the IIFE is synchronous — evaluateJavaScript does not flatten
        // promises in this WebKit. The real check flow (card click) is timed
        // app-side instead: the app samples the card mid-ramp and reads the
        // settled state once its own check completes (armSelfTestCheckFlow /
        // selfTestCheckCompleted); the final output waits for it (bounded).
        let js = """
        (() => {
        try {
          let confirmWired = null;
          if (window.__autoconfirm) confirmWired = confirm('selftest');
          const row = [...document.querySelectorAll('#rows-cpu .row')].find(r => r.style.display !== 'none');
          if (row) row.click();
          const drawerRows = document.querySelectorAll('#dtable .prow').length;
          const memPressure = document.querySelector('#mem-pressure')?.textContent || null;
          const hasDrawerActions = !!document.querySelector('#dcopy') && !!document.querySelector('#d-net-box') && !!document.querySelector('#dblist');
          document.querySelector('#dclose')?.click();
          const energyBtn = document.querySelector('#cpu-mode-energy');
          energyBtn?.click();
          const energyToggleOk = !!energyBtn && document.querySelectorAll('#rows-cpu .row').length > 0;
          document.querySelector('#cpu-mode-cpu')?.click();
          document.querySelector('#bg-items-btn')?.click();
          const bgItemsOpen = document.querySelector('#bg-scrim')?.classList.contains('on') || false;
          document.querySelector('#bg-close')?.click();
          const bgItemsClosed = !document.querySelector('#bg-scrim')?.classList.contains('on');
          const bgItemsModalOk = bgItemsOpen && bgItemsClosed;
          document.querySelector('#bl-btn')?.click();
          const blOpenState = document.querySelector('#bl-scrim')?.classList.contains('on') || false;
          document.querySelector('#bl-close')?.click();
          const blClosedState = !document.querySelector('#bl-scrim')?.classList.contains('on');
          const blacklistModalOk = blOpenState && blClosedState;
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
          // Updates card: fake a found update through the same handler the app uses
          // (web-only — the app's Sparkle state is untouched), verify the card swap
          // and the button label, then restore the real version.
          const realVer = (document.querySelector('#ver')?.textContent || '').replace(/^v/, '');
          window.__pulseUpdate && window.__pulseUpdate({ current: realVer + '-x', available: realVer + '-x' });
          const updBtnText = document.querySelector('#st-update-btn')?.textContent || '';
          const updateCardSwaps = realVer !== ''
            && !document.querySelector('#st-update-card')?.hidden
            && document.querySelector('#st-check-card')?.hidden
            && updBtnText.includes(realVer);
          window.__pulseUpdate && window.__pulseUpdate({ current: realVer });
          const checkCardRestored = !document.querySelector('#st-check-card')?.hidden;
          // Real check flow — regression for "the text said up to date before the
          // bar finished". Reopen the modal (the bar must be visible to measure)
          // and click the real button. evaluateJavaScript does not flatten
          // promises in this WebKit, so all timing lives app-side: the app
          // samples the card mid-ramp and reads the settled state once its own
          // check completes (see armSelfTestCheckFlow / selfTestCheckCompleted).
          document.querySelector('#settings-btn')?.click();
          document.querySelector('#st-check-btn')?.click();
          return JSON.stringify({
            machine: document.querySelector('#machine')?.textContent,
            ver: document.querySelector('#ver')?.textContent,
            cpu: document.querySelector('#cpu-big')?.textContent,
            mem: document.querySelector('#mem-big')?.textContent,
            rows: document.querySelectorAll('#rows-cpu .row').length,
            live: document.querySelector('#live-text')?.textContent,
            confirmWired, drawerRows, memPressure, drawerExtrasOk: hasDrawerActions, memInfo,
            energyToggleOk, bgItemsModalOk, blacklistModalOk,
            dashboardSettingsOk: dashboardSettingsOpen && dashboardSettingsClosed,
            updatesCardOk: updateCardSwaps && checkCardRestored,
            purgeBtn: !!document.querySelector('#mem-purge')
          });
        } catch (e) {
          return JSON.stringify({ selfTestError: String((e && e.message) || e) });
        }
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
            // The check flow resolves from the app when the real check completes;
            // bound it so a check that never completes (offline) can't hold the
            // final output forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [weak self] in
                guard let self, !self.selfTestFinishFired else { return }
                self.selfTestFlowResolved = true
                self.selfTestBackgroundDone = true   // bound this too — a slow fetch must not hang the output
                if self.selfTestBackground == nil { self.selfTestBackground = ["timedOut": true] }
                self.maybeFinishSelfTest()
            }
        }
    }

    // The self-test's real check flow: all timing lives app-side (this WebKit's
    // evaluateJavaScript doesn't flatten promises). `armSelfTestCheckFlow` fires
    // when the page clicks the real card button: it samples the card mid-ramp at
    // 200ms — which must precede the lifecycle's webview release — and
    // `selfTestCheckCompleted` (called from every terminal Sparkle path) reads
    // the settled card after the ramp/hop margin. The final output waits for
    // BOTH the lifecycle and this flow, bounded by a timeout; the landing
    // retries while the webview is released (the window is closed and reopened
    // during the lifecycle).
    private var selfTestFlowArmed = false
    private var selfTestSampleTaken = false
    private var selfTestLandingArmed = false
    private var selfTestWebStatePushedAt: Date?
    private var selfTestCheckFlowSample: [String: Any]?
    private var selfTestCheckFlow: [String: Any]?
    private var selfTestFlowResolved = false
    private var selfTestBackgroundQueued = false
    private var selfTestBgCheckPending = false
    private var selfTestBackgroundDone = false
    private var selfTestBackground: [String: Any]?
    private var selfTestStartingProbe: [String: Any]?
    private var selfTestLifecycleDone = false
    private var selfTestFinishFired = false
    private var selfTestFinishHandler: (() -> Void)?

    private func maybeFinishSelfTest() {
        guard selfTestLifecycleDone, selfTestFlowResolved, selfTestBackgroundDone, !selfTestFinishFired else { return }
        selfTestFinishFired = true
        selfTestFinishHandler?()
        selfTestFinishHandler = nil
    }

    // Card-state probe shared by the mid-ramp sample and the settled-state read.
    // The conditional modal-open makes it work both pre-release (the flow leaves
    // the modal open) and post-reopen (fresh page, modal closed). The bar width
    // ratio is only meaningful while the card is visible; barOpacity covers the
    // faded-out success state.
    private static let selfTestCardJS = """
        (() => {
          if (document.querySelector('#settings-scrim')?.classList.contains('on') !== true) {
            document.querySelector('#settings-btn')?.click();
          }
          const f = document.querySelector('#st-check-bar-fill');
          const t = document.querySelector('#st-check-bar');
          const fw = f ? parseFloat(getComputedStyle(f).width) : -1;
          const tw = t ? parseFloat(getComputedStyle(t).width) : -1;
          const out = {
            desc: document.querySelector('#st-check-desc')?.textContent || '',
            bar: (t && tw > 0) ? fw / tw : -1,
            fillInline: f ? f.style.width : '',
            barOpacity: t ? parseFloat(getComputedStyle(t).opacity) : -1,
            btnDisabled: document.querySelector('#st-check-btn')?.disabled || false,
            updateCard: document.querySelector('#st-update-card')?.hidden === false
          };
          document.querySelector('#settings-close')?.click();
          return JSON.stringify(out);
        })()
        """

    /// The self-test clicked the real check button: sample the card 200ms in —
    /// mid-ramp (the ramp is 1.1s), and safely before the lifecycle's webview
    /// release. The sync invariant under test: even if the result already
    /// arrived, the desc must still say "Checking…" with the bar mid-fill.
    private func armSelfTestCheckFlow() {
        guard !selfTestFlowArmed else { return }
        selfTestFlowArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if let w = self.web, self.pageLoaded {
                w.evaluateJavaScript(Self.selfTestCardJS) { d, _ in
                    if let s = d as? String,
                       var obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
                        obj["stage"] = "sample"
                        self.selfTestCheckFlowSample = obj
                    }
                    self.selfTestSampleTaken = true
                }
            } else {
                self.selfTestSampleTaken = true   // webview already released — nothing to sample
            }
        }
    }

    /// Terminal path of the update check (called from `updateCheckFoundNothing`,
    /// `updateCheckFailed` and `didFindValidUpdate`). In the self-test: wait for
    /// the ramp+hop margin so the card has fully settled, then read it.
    private func selfTestCheckCompleted() {
        guard isSelfTest else { return }
        // The self-test's second check runs in the *background* — the scheduled
        // path. For it Sparkle never invokes the user driver (an up-to-date
        // background check shows nothing), so the outcome must classify
        // correctly on the delegate side alone: an up-to-date result must land
        // as a success, not a failure. App-side read only, so the lifecycle's
        // webview release can't starve it.
        if selfTestBgCheckPending {
            selfTestBgCheckPending = false
            selfTestBackground = [
                "failed": lastCheckFailed,
                "checkedAtStamped": lastCheckAtMs != nil,
                "pendingVersion": pendingUpdateVersion as Any
            ]
            selfTestBackgroundDone = true
            maybeFinishSelfTest()
            return
        }
        guard selfTestFlowArmed, !selfTestLandingArmed, !selfTestFlowResolved else { return }
        selfTestLandingArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.landSelfTestCheck(attempts: 40)
        }
        if !selfTestBackgroundQueued {
            selfTestBackgroundQueued = true
            queueSelfTestBackgroundCheck(remainingAttempts: 40)   // ≤ 20s for the first check's session to end
        }
    }

    /// Fires the self-test's background check once the first (user-initiated)
    /// check's Sparkle session has fully ended — `checkForUpdatesInBackground`
    /// is a silent no-op while a session is in progress.
    private func queueSelfTestBackgroundCheck(remainingAttempts: Int) {
        guard remainingAttempts > 0 else { return }
        if !updater.sessionInProgress {
            selfTestBgCheckPending = true
            updater.checkForUpdatesInBackground()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.queueSelfTestBackgroundCheck(remainingAttempts: remainingAttempts - 1)
        }
    }

    private func landSelfTestCheck(attempts: Int) {
        guard !selfTestFlowResolved else { return }
        guard selfTestSampleTaken else {
            guard attempts > 0 else { return resolveSelfTestFlow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.landSelfTestCheck(attempts: attempts - 1)
            }
            return
        }
        guard let w = web, pageLoaded else {
            guard attempts > 0 else { return resolveSelfTestFlow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.landSelfTestCheck(attempts: attempts - 1)
            }
            return
        }
        // A freshly reloaded page must have received its state push (didFinish) —
        // otherwise the card is still in its idle state and the read is meaningless.
        if let pushed = selfTestWebStatePushedAt, Date().timeIntervalSince(pushed) < 0.3 {
            guard attempts > 0 else { return resolveSelfTestFlow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.landSelfTestCheck(attempts: attempts - 1)
            }
            return
        }
        w.evaluateJavaScript(Self.selfTestCardJS) { [weak self] d, _ in
            guard let self else { return }
            if let s = d as? String,
               var obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
                obj["stage"] = "done"
                self.selfTestCheckFlow = obj
            }
            self.resolveSelfTestFlow()
        }
    }

    private func resolveSelfTestFlow() {
        selfTestFlowResolved = true
        maybeFinishSelfTest()
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

        // 1b. Update strip layout invariant: when visible, strip is 24px tall,
        // its label is horizontally & vertically centered (not knocked to bottom-left),
        // and the webview sits below it without overlapping; when hidden, the webview
        // reclaims the full content-view top.
        var updateStripOk = false
        var updateStripInfo: [String: Any] = [:]
        if let cv = window.contentView {
            let prevPending = pendingUpdateVersion
            pendingUpdateVersion = "9.9.9"
            setUpdateIndicators()
            cv.layoutSubtreeIfNeeded()
            let sf = updateStrip.frame
            let lf = updateStrip.labelFrame
            let wf = web?.frame ?? .zero
            let hOk = !updateStrip.isHidden && abs(sf.height - UpdateStripView.height) < 0.5
            let centeredXOk = abs(lf.midX - updateStrip.bounds.midX) <= 1.5
            let centeredYOk = abs(lf.midY - updateStrip.bounds.midY) <= 1.5
            let noOverlapOk = wf.maxY <= sf.minY + 0.5 && wf.height > 0

            pendingUpdateVersion = prevPending
            setUpdateIndicators()
            cv.layoutSubtreeIfNeeded()
            let hiddenRestoreOk = (prevPending != nil) || (updateStrip.isHidden && (web?.frame.maxY ?? 0) >= cv.bounds.maxY - 0.5)
            updateStripOk = hOk && centeredXOk && centeredYOk && noOverlapOk && hiddenRestoreOk
            updateStripInfo = [
                "stripH": sf.height,
                "labelX": Double(lf.origin.x),
                "labelMidX": Double(lf.midX),
                "stripMidX": Double(updateStrip.bounds.midX),
                "centeredXOk": centeredXOk,
                "centeredYOk": centeredYOk,
                "noOverlapOk": noOverlapOk,
                "hiddenRestoreOk": hiddenRestoreOk,
            ]
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
            self.pollReopenRender(reopenStart: reopenStart, attemptsLeft: 30) { [self] reopenOk, reopenMs in
                // 4. Final output — runs exactly once, and only when BOTH the
                // lifecycle checks and the check flow are done (the flow may
                // arrive first, or be cut off by its timeout — the handler then
                // reports what it has).
                self.selfTestLifecycleDone = true
                self.selfTestFinishHandler = {
                    // LaunchAgent install/remove round-trip (uses isolated label local.pulse.monitor.selftest).
                    var daemonRoundTripOk = false
                    var daemonPortOwnerOk = false
                    if let node = findNodeFast() {
                        let mgr = LaunchAgentManager.shared
                        let pf = portFilePath()
                        try? FileManager.default.removeItem(atPath: pf)
                        if case .success = mgr.installAndBootstrap(nodePath: node) {
                            let installedOk = mgr.plistExists && mgr.isLoaded()
                            let deadline = Date().addingTimeInterval(3.0)
                            while Date() < deadline {
                                if let info = readPortFileInfo(path: pf),
                                   let pid = info.pid, pid != getpid(), isProcessAlive(pid) {
                                    daemonPortOwnerOk = true
                                    break
                                }
                                usleep(50_000)
                            }
                            _ = mgr.uninstall()
                            let removedOk = !mgr.plistExists && !mgr.isLoaded()
                            try? FileManager.default.removeItem(atPath: pf)
                            daemonRoundTripOk = installedOk && removedOk
                        }
                    }
                    let traceText = (try? String(contentsOfFile: BootTracer.shared.logPath, encoding: .utf8)) ?? ""
                    let traceOk = traceText.contains("stage=app_launch") &&
                                  traceText.contains("stage=skeleton_paint") &&
                                  traceText.contains("stage=first_render") &&
                                  traceText.contains("stage=window_reopen")
                    try? FileManager.default.removeItem(atPath: BootTracer.shared.logPath)
                    try? FileManager.default.removeItem(atPath: pulseDir + "/daemon-selftest.log")

                    var startingSkeletonOk = false
                    if let sk = self.selfTestStartingProbe {
                        startingSkeletonOk =
                            (sk["protocol"] as? String) == "file:" &&
                            (sk["live"] as? String) == "starting…" &&
                            ((sk["skelRows"] as? Int) ?? 0) > 0 &&
                            (sk["hasSetter"] as? Bool) == true &&
                            ((sk["cpuText"] as? String) ?? "") == ""
                    }

                    restoreSettings()
                    var merged = (try? JSONSerialization.jsonObject(with: Data(initialJson.utf8)) as? [String: Any]) ?? [:]
                    if let sk = self.selfTestStartingProbe {
                        merged["startingSkeleton"] = sk
                    }
                    merged["startingSkeletonOk"] = startingSkeletonOk
                    merged["lifecycle"] = [
                        "settingsVisible": settingsVisible,
                        "settingsRoundTripOk": settingsRoundTripOk,
                        "updateStripOk": updateStripOk,
                        "updateStrip": updateStripInfo,
                        "closedWindowHidden": closedWindowHidden,
                        "closedWebReleased": closedWebReleased,
                        "backendAliveWhileClosed": backendAliveWhileClosed,
                        "reopenRenderOk": reopenOk,
                        "reopenMs": reopenMs,
                        "daemonRoundTripOk": daemonRoundTripOk,
                        "daemonPortOwnerOk": daemonPortOwnerOk,
                        "bootTraceOk": traceOk,
                    ]
                    // Check flow: the mid-ramp sample is the sync regression assertion;
                    // the terminal state must have landed (bar full, or card swapped).
                    let sample = self.selfTestCheckFlowSample
                    if let sample { merged["checkFlowSample"] = sample }
                    if let flow = self.selfTestCheckFlow {
                        merged["checkFlow"] = flow
                        if (flow["stage"] as? String) == "done" {
                            // The inline fill width is the deterministic signal: it is
                            // 92% (or sliding) while checking and only becomes 100% when
                            // the result lands. The computed ratio lags the animation.
                            var sampleOk = ((sample?["desc"] as? String) ?? "").contains("Checking for updates")
                                && (sample?["btnDisabled"] as? Bool) == true
                                && (sample?["fillInline"] as? String) != "100%"
                            if let sBar = sample?["bar"] as? Double, sBar >= 0 {
                                sampleOk = sampleOk && sBar < 0.99   // unmeasurable (-1) is fine; a measured value must be mid-ramp
                            }
                            let dBar = (flow["bar"] as? Double) ?? -1
                            let dFill = flow["fillInline"] as? String ?? ""
                            let dOpacity = (flow["barOpacity"] as? Double) ?? 1
                            merged["checkFlowOk"] = sampleOk
                                && (flow["btnDisabled"] as? Bool) == false
                                && ((flow["updateCard"] as? Bool) == true || dBar >= 0.99 || dFill == "100%" || dOpacity < 0.5)
                        } else {
                            // Only the sample arrived (the webview was released mid-check,
                            // e.g. offline): assert the sample alone, flag the gap.
                            let sBar = (sample?["bar"] as? Double) ?? -1
                            merged["checkFlowOk"] = ((sample?["desc"] as? String) ?? "").contains("Checking for updates")
                                && (sample?["btnDisabled"] as? Bool) == true
                                && (sample?["fillInline"] as? String) != "100%"
                                && sBar < 0.99
                            merged["checkFlowTimedOut"] = true
                        }
                    } else if self.selfTestCheckFlowSample != nil {
                        merged["checkFlowTimedOut"] = true   // sample kept, terminal state lost
                    }
                    // The background (scheduled-path) check: an up-to-date outcome must
                    // land as a *success* — the regression that made every hourly check
                    // mark itself “couldn't check”. (nil = it never ran: slow first
                    // check or no network; reported, not fatal.)
                    if let bg = self.selfTestBackground {
                        merged["checkFlowBackground"] = bg
                        merged["checkFlowBackgroundOk"] = (bg["failed"] as? Bool) == false
                    } else {
                        merged["checkFlowBackgroundOk"] = false
                        merged["checkFlowBackgroundTimedOut"] = true
                    }
                    let outData = (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])) ?? Data()
                    let outStr = String(data: outData, encoding: .utf8) ?? initialJson
                    let statusOk = self.status?.samples ?? 0
                    print("SELFTEST: " + outStr +
                          " port=" + String(self.serverPort ?? -1) +
                          " statusItemSamples=" + String(statusOk) +
                          " statusItemImage=" + ((self.status?.item.button?.image != nil) ? "ok" : "missing"))
                    NSApp.terminate(nil)
                }
                self.maybeFinishSelfTest()
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
        a.window.appearance = NSAppearance(named: .darkAqua)
        a.messageText = "Pulse"
        a.informativeText = msg
        a.alertStyle = .warning
        a.runModal()
        NSApp.terminate(nil)
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWebLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleWebLoadFailure(error)
    }

    private func handleWebLoadFailure(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        revealWebView()
        showFatal("Could not load the Pulse dashboard:\n\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageLoaded = false
        if let url = webView.url,
           let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let b = comp.queryItems?.first(where: { $0.name == "backend" })?.value {
            injectedBackendUrl = b
        } else {
            injectedBackendUrl = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.revealWebView()
        }
        pushSettingsToWeb()
        pushUpdateToWeb()
        selfTestWebStatePushedAt = Date()
        if ProcessInfo.processInfo.environment["PULSE_AUTOCONFIRM"] == "1" {
            web?.evaluateJavaScript("window.__autoconfirm = true; true") { _, _ in }
        }
        if isSelfTest && selfTestStartingProbe == nil && injectedBackendUrl == nil {
            let probeJs = """
            JSON.stringify({
              protocol: location.protocol,
              live: document.querySelector('#live-text')?.textContent || '',
              skelRows: document.querySelectorAll('.skel-row').length,
              hasSetter: typeof window.__pulseSetBackend === 'function',
              cpuText: document.querySelector('#cpu-big')?.textContent || ''
            })
            """
            webView.evaluateJavaScript(probeJs) { [weak self] res, _ in
                if let s = res as? String,
                   let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                    self?.selfTestStartingProbe = obj
                }
                self?.syncBackendToWeb()
            }
            return
        }
        syncBackendToWeb()
    }

    // MARK: WKUIDelegate — native dialogs for confirm()/alert()/prompt()
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.window.appearance = NSAppearance(named: .darkAqua)
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
        a.window.appearance = NSAppearance(named: .darkAqua)
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
        a.window.appearance = NSAppearance(named: .darkAqua)
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
        // Kill any backend (active or retiring racer) spawned directly by this app process.
        var toStop = retiredProcs
        if spawnedNode, let p = nodeProc { toStop.append(p) }
        for p in toStop where p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while toStop.contains(where: { $0.isRunning }) && Date() < deadline { usleep(50_000) }
        for p in toStop where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        while toStop.contains(where: { $0.isRunning }) { usleep(50_000) }
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
