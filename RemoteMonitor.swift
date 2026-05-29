import Foundation

// MARK: - Remote (Mac mini) terminal monitor
//
// Polls ~/.navi/mini_probe.sh on a timer to learn how many terminals are alive
// on the Mac mini (over Tailscale) and which are busy, and runs ad-hoc commands
// via ~/.navi/mini_run.sh for the "Ask the mini…" box. All shell work happens off
// the main thread; callbacks are delivered back on the main thread.

struct RemoteStatus {
    let shells: Int
    let busy: Int
    let names: [String]
    let reachable: Bool
    /// Per-terminal foreground command keyed by tty ("-" means idle at the prompt).
    let terminals: [String: String]

    static let offline = RemoteStatus(shells: 0, busy: 0, names: [], reachable: false, terminals: [:])
}

final class RemoteMonitor {
    var onUpdate: ((RemoteStatus) -> Void)?

    private let probeScript: String
    private let runScript: String
    private let interval: TimeInterval = 4.0
    // Separate queues so a stalled background poll can't delay an on-demand
    // (⌘⇧M) command, and vice-versa.
    private let pollQueue = DispatchQueue(label: "navi.remote.poll", qos: .utility)
    private let runQueue = DispatchQueue(label: "navi.remote.run", qos: .userInitiated)
    private var timer: Timer?

    init() {
        let naviDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".navi")
        probeScript = naviDir.appendingPathComponent("mini_probe.sh").path
        runScript = naviDir.appendingPathComponent("mini_run.sh").path
    }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Stop polling (e.g. while the display is asleep — no point churning SSH then).
    func pause() {
        timer?.invalidate()
        timer = nil
    }

    /// Resume polling, taking an immediate fresh sample.
    func resume() {
        start()
    }

    private func poll() {
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let out = RemoteMonitor.runShell(self.probeScript, args: [], timeout: 8)
            let status = RemoteMonitor.parse(out)
            DispatchQueue.main.async { self.onUpdate?(status) }
        }
    }

    /// Run an arbitrary command (or "__status__") on the mini; output returns on main thread.
    func runRemote(_ command: String, completion: @escaping (String) -> Void) {
        runQueue.async {
            let out = RemoteMonitor.runShell(self.runScript, args: [command], timeout: 20)
            DispatchQueue.main.async { completion(out) }
        }
    }

    static func parse(_ raw: String) -> RemoteStatus {
        for line in raw.split(whereSeparator: \.isNewline) where line.hasPrefix("NAVI") {
            var terminals: [String: String] = [:]
            for token in line.dropFirst("NAVI".count).split(separator: " ") {
                let kv = token.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                terminals[String(kv[0])] = String(kv[1])
            }
            let busyCmds = terminals.values.filter { $0 != "-" }
            return RemoteStatus(shells: terminals.count,
                                busy: busyCmds.count,
                                names: Array(busyCmds),
                                reachable: true,
                                terminals: terminals)
        }
        return .offline
    }

    private static func runShell(_ scriptPath: String, args: [String], timeout: TimeInterval) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return ""
        }
        // Watchdog: terminate a stalled invocation so it can't hang the queue or
        // leave SSH lingering indefinitely.
        let killer = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain before waiting so a large payload can't deadlock the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
