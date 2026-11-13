import Foundation
import IOKit.ps
import UserNotifications

/// Rules for long unattended runs.
struct RunRules: Codable, Hashable {
    var onlyBetween = false
    var startHour = 23
    var endHour = 7
    var pauseOnBattery = true
    var pauseWhenHot = true
    var notifyMac = true
    var webhookURL = ""                  // e.g. an ntfy.sh topic, Pushover or Home Assistant webhook → iPhone

    static var current: RunRules {
        get { (Prefs.store.data(forKey: "runRules")).flatMap { try? JSONDecoder().decode(RunRules.self, from: $0) } ?? RunRules() }
        set { Prefs.store.set(try? JSONEncoder().encode(newValue), forKey: "runRules") }
    }
}

/// Every long-running loop calls `wait()` between frames/chunks: work pauses (without losing anything) while the
/// user has paused, the Mac is on battery, it's too hot, or it's outside the allowed hours.
actor PauseGate {
    static let shared = PauseGate()
    private(set) var userPaused = false
    private var lastReason = ""

    func setPaused(_ p: Bool) { userPaused = p }

    func reason() -> String? {
        let r = RunRules.current
        if userPaused { return "Paused" }
        if r.pauseOnBattery, PowerState.onBattery { return "Paused: on battery" }
        if r.pauseWhenHot, ProcessInfo.processInfo.thermalState == .critical { return "Paused: Mac is very hot" }
        if r.onlyBetween, !Self.inWindow(r) { return "Waiting for \(r.startHour):00" }
        return nil
    }

    func wait() async {
        while let why = reason() {
            if why != lastReason { Log.notice(.app, why); lastReason = why }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
        }
        if !lastReason.isEmpty { Log.notice(.app, "Resumed"); lastReason = "" }
    }

    static func inWindow(_ r: RunRules, now: Date = Date()) -> Bool {
        let h = Calendar.current.component(.hour, from: now)
        return r.startHour <= r.endHour ? (h >= r.startHour && h < r.endHour) : (h >= r.startHour || h < r.endHour)
    }
}

enum PowerState {
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}

/// "Done" messages: a Mac notification and, if set, a webhook that reaches your phone.
enum Notifier {
    static func requestPermission() {
        // Only ask when Mac notifications are switched on; a webhook-only setup never needs the system prompt.
        guard RunRules.current.notifyMac else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, _ body: String) {
        let r = RunRules.current
        if r.notifyMac {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        if let url = URL(string: r.webhookURL), !r.webhookURL.isEmpty {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(title, forHTTPHeaderField: "Title")          // ntfy.sh reads this header
            req.httpBody = Data(body.utf8)
            URLSession.shared.dataTask(with: req).resume()
        }
    }
}

/// The batch queue survives quitting and crashes: unfinished files are picked up again next launch, and files
/// whose finished output already exists and checks out are skipped.
struct QueueStore {
    struct Item: Codable, Hashable { var source: String; var output: String?; var done: Bool; var folder: String? = nil }
    private static var url: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("queue.json")
    }
    static func load() -> [Item] { (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: url))) ?? [] }
    static func save(_ items: [Item]) { try? JSONEncoder().encode(items).write(to: url) }
    static func markDone(_ source: URL, output: URL) {
        var q = load()
        if let i = q.firstIndex(where: { $0.source == source.path }) { q[i].done = true; q[i].output = output.path }
        save(q)
    }
    static func enqueue(_ files: [URL], folder: URL) {
        var q = load().filter { !$0.done }
        for f in files where !q.contains(where: { $0.source == f.path }) { q.append(Item(source: f.path, output: nil, done: false, folder: folder.path)) }
        save(q)
    }
    static var pendingFolder: URL? { load().first { !$0.done }?.folder.map { URL(fileURLWithPath: $0) } }
    static var pending: [URL] { load().filter { !$0.done }.map { URL(fileURLWithPath: $0.source) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
}
