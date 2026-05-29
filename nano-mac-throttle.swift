import AppKit
import Foundation

private let thermalPressureNotificationName = "com.apple.system.thermalpressurelevel"

@_silgen_name("notify_register_check")
private func c_notify_register_check(_ name: UnsafePointer<CChar>, _ outToken: UnsafeMutablePointer<Int32>) -> UInt32

@_silgen_name("notify_register_dispatch")
private func c_notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @convention(block) @escaping (Int32) -> Void
) -> UInt32

@_silgen_name("notify_get_state")
private func c_notify_get_state(_ token: Int32, _ state64: UnsafeMutablePointer<UInt64>) -> UInt32

@_silgen_name("notify_cancel")
@discardableResult
private func c_notify_cancel(_ token: Int32) -> UInt32

enum ThermalState: Int, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3
    case unknown = -1

    static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        lhs.rank < rhs.rank
    }

    static func current() -> ThermalState {
        from(ProcessInfo.processInfo.thermalState)
    }

    static func from(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    var rank: Int {
        switch self {
        case .unknown: return -1
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        case .unknown: return "unknown"
        }
    }

    var isWarm: Bool {
        self == .fair || isFallbackThrottle
    }

    var isFallbackThrottle: Bool {
        self == .serious || self == .critical
    }

}

enum ThermalPressure: UInt64, Comparable {
    case nominal = 0
    case moderate = 1
    case heavy = 2
    case trapping = 3
    case sleeping = 4
    case unknown = 999

    static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool {
        lhs.rank < rhs.rank
    }

    static func fromRaw(_ raw: UInt64) -> ThermalPressure {
        ThermalPressure(rawValue: raw) ?? .unknown
    }

    var rank: Int {
        switch self {
        case .unknown: return -1
        case .nominal: return 0
        case .moderate: return 1
        case .heavy: return 2
        case .trapping: return 3
        case .sleeping: return 4
        }
    }

    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .moderate: return "moderate"
        case .heavy: return "heavy"
        case .trapping: return "trapping"
        case .sleeping: return "sleeping"
        case .unknown: return "unknown"
        }
    }

    var isPressure: Bool {
        self == .moderate || isThrottle
    }

    var isThrottle: Bool {
        self == .heavy || self == .trapping || self == .sleeping
    }
}

enum MemoryPressureLevel: Int, Comparable {
    case unknown = -1
    case normal = 0
    case medium = 1
    case high = 2

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func fromEvent(_ event: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        if event.contains(.critical) { return .high }
        if event.contains(.warning) { return .medium }
        if event.contains(.normal) { return .normal }
        return .unknown
    }

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .normal: return "normal"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    var isPressure: Bool {
        self == .medium || self == .high
    }
}

enum NotificationSeverity {
    case small
    case important
}

enum NotificationMode: String {
    case all
    case important
    case off

    var label: String {
        switch self {
        case .all: return "All alerts"
        case .important: return "Important only"
        case .off: return "Off"
        }
    }
}

// Titles that represent a real problem worth interrupting for. Everything else
// (heads-ups, recoveries, level changes) is a small alert.
private let importantNotificationTitles: Set<String> = [
    "Mac CPU throttling",
    "Mac thermal alert",
    "Mac thermal alert - serious",
    "Mac thermal alert - critical",
    "Mac memory pressure - high",
]

func notificationSeverity(forTitle title: String) -> NotificationSeverity {
    importantNotificationTitles.contains(title) ? .important : .small
}

// Pure gate decision: should a notification of this severity be shown given the
// current mode and whether a snooze is active? Snooze is a total mute.
func notificationAllowed(severity: NotificationSeverity, mode: NotificationMode, snoozed: Bool) -> Bool {
    if snoozed { return false }
    switch mode {
    case .off: return false
    case .important: return severity == .important
    case .all: return true
    }
}

struct ProcessMemory {
    let kilobytes: Int
    let name: String
}

struct TopMemoryRow {
    let pid: Int
    let kilobytes: Int
    let fallbackName: String
}

@discardableResult
func run(_ path: String, _ args: [String], timeoutMs: Int = 5000) -> (stdout: String, exitCode: Int32) {
    let process = Process()
    let out = Pipe()
    let err = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = out
    process.standardError = err

    do {
        try process.run()
    } catch {
        return ("", -1)
    }

    // Drain stdout and stderr on background threads. A child that writes more
    // than the pipe buffer (~64 KB) blocks until someone reads; reading stdout
    // only after exit — and never reading stderr at all — can deadlock the
    // child against our timeout and lose its output. ps/top can hit this on a
    // busy machine.
    let lock = NSLock()
    var outData = Data()
    let group = DispatchGroup()
    let readQueue = DispatchQueue(label: "nano-mac-throttle.run", attributes: .concurrent)

    group.enter()
    readQueue.async {
        let data = out.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); outData = data; lock.unlock()
        group.leave()
    }
    group.enter()
    readQueue.async {
        _ = err.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    var timedOut = false
    while process.isRunning {
        if Date() > deadline {
            process.terminate()
            timedOut = true
            break
        }
        usleep(50_000)
    }

    // The reads finish once both write ends close (on normal exit or terminate),
    // so this returns promptly in either case.
    group.wait()
    process.waitUntilExit()

    if timedOut {
        return ("", -2)
    }

    lock.lock(); let captured = outData; lock.unlock()
    return (String(data: captured, encoding: .utf8) ?? "", process.terminationStatus)
}

func notifyUser(_ title: String, _ body: String) {
    let sanitize: (String) -> String = {
        $0.replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\"", with: "\\\"")
    }
    let script = "display notification \"\(sanitize(body))\" with title \"\(sanitize(title))\""
    _ = run("/usr/bin/osascript", ["-e", script])
}

func infoMenuItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = true
    return item
}

func infoMenuItem(_ title: String, symbolName: String, accessibilityDescription: String) -> NSMenuItem {
    let item = infoMenuItem(title)
    if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) {
        image.isTemplate = true
        item.image = image
    }
    return item
}

func readDarwinPressureOnce() -> ThermalPressure? {
    var token: Int32 = 0
    let registerStatus = thermalPressureNotificationName.withCString {
        c_notify_register_check($0, &token)
    }
    guard registerStatus == 0 else { return nil }
    defer { c_notify_cancel(token) }

    var state: UInt64 = 0
    let stateStatus = c_notify_get_state(token, &state)
    guard stateStatus == 0 else { return nil }
    return ThermalPressure.fromRaw(state)
}

func topCPU(_ count: Int) -> [String] {
    let raw = run("/bin/ps", ["-Ao", "pcpu,comm", "-r"]).stdout
    let processorCount = max(ProcessInfo.processInfo.processorCount, 1)
    var results: [String] = []

    for line in raw.split(separator: "\n").dropFirst() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else { continue }
        let percentText = String(trimmed[..<spaceIndex])
        let command = trimmed[trimmed.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
        guard let percent = Double(percentText), percent > 5 else { continue }

        let name = (command as NSString).lastPathComponent
        let totalPercent = percent / Double(processorCount)
        results.append(String(format: "%@ %.0f%% core / %.0f%% total", name, percent, totalPercent))
        if results.count >= count { break }
    }

    return results
}

func topUsersSummary(_ users: [String], emptyMessage: String) -> String {
    users.isEmpty ? emptyMessage : users.joined(separator: ", ")
}

func addTopUsersMenuItems(to menu: NSMenu, title: String, users: [String], emptyMessage: String) {
    menu.addItem(infoMenuItem(title))
    if users.isEmpty {
        menu.addItem(infoMenuItem("  \(emptyMessage)"))
    } else {
        for user in users {
            menu.addItem(infoMenuItem("  - \(user)"))
        }
    }
}

func thermalNotificationBody(state: String, topCPUUsers: [String]) -> String {
    """
    Thermal state : \(state)
    Top CPU users : \(topUsersSummary(topCPUUsers, emptyMessage: "no dominant CPU user"))
    """
}

func memoryNotificationBody(level: String, freePercentage: String, topMemoryUsers: [String]) -> String {
    """
    Memory pressure : \(level) (Free = \(freePercentage))
    Top Memory users : \(topUsersSummary(topMemoryUsers, emptyMessage: "unavailable"))
    """
}

let sampleTopCPUUsers = [
    "Xcode 188% core / 24% total",
    "Safari 96% core / 12% total",
    "Docker VM 72% core / 9% total",
]

let sampleTopMemoryUsers = [
    "Docker VM 9.5 GB",
    "Xcode 3.2 GB",
    "Safari 1.4 GB",
]

func thermalDisplayLabel(
    thermalState: ThermalState,
    darwinAvailable: Bool,
    thermalPressure: ThermalPressure
) -> String {
    if thermalState == .nominal { return ThermalState.nominal.label }
    if darwinAvailable && thermalPressure != .unknown {
        return thermalPressure.label
    }
    return thermalState.label
}

func memoryFreePercentage(from output: String) -> String? {
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("System-wide memory free percentage:") else { continue }
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { continue }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }
    return nil
}

func memoryPressureSummary(from output: String) -> String? {
    memoryFreePercentage(from: output).map { "free memory: \($0)" }
}

func currentMemoryPressureSummary() -> String {
    let result = run("/usr/bin/memory_pressure", [], timeoutMs: 3000)
    guard result.exitCode == 0 else { return "memory_pressure unavailable" }
    return memoryPressureSummary(from: result.stdout) ?? "memory_pressure summary unavailable"
}

func currentMemoryFreePercentage() -> String {
    let result = run("/usr/bin/memory_pressure", [], timeoutMs: 3000)
    guard result.exitCode == 0 else { return "unavailable" }
    return memoryFreePercentage(from: result.stdout) ?? "unavailable"
}

func appName(from command: String) -> String {
    if command.contains("/Applications/Docker.app/") && command.contains("com.docker.virtualization") {
        return "Docker VM"
    }

    if command.contains("/System/Library/Frameworks/Virtualization.framework/")
        && command.contains("com.apple.Virtualization.VirtualMachine") {
        return "Docker VM"
    }

    if let appRange = command.range(of: ".app/Contents/") {
        let beforeApp = command[..<appRange.lowerBound]
        if let slash = beforeApp.lastIndex(of: "/") {
            return String(beforeApp[beforeApp.index(after: slash)...])
                .replacingOccurrences(of: ".app", with: "")
        }
    }

    let firstArgument = command.split(separator: " ").first.map(String.init) ?? command
    return (firstArgument as NSString).lastPathComponent
}

func formatMemory(kilobytes: Int) -> String {
    let megabytes = Double(kilobytes) / 1024.0
    if megabytes >= 1024 {
        return String(format: "%.1f GB", megabytes / 1024.0)
    }
    return String(format: "%.0f MB", megabytes)
}

func parseTopMemoryKilobytes(_ value: String) -> Int? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard let unit = trimmed.last else { return nil }
    let numberText = String(trimmed.dropLast())
    guard let number = Double(numberText) else { return nil }

    switch unit {
    case "K", "k":
        return Int(number.rounded())
    case "M", "m":
        return Int((number * 1024.0).rounded())
    case "G", "g":
        return Int((number * 1024.0 * 1024.0).rounded())
    default:
        guard let bytes = Double(trimmed) else { return nil }
        return Int((bytes / 1024.0).rounded())
    }
}

func processCommandMap(from psOutput: String) -> [Int: String] {
    var commands: [Int: String] = [:]

    for line in psOutput.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else { continue }

        let pidText = String(trimmed[..<spaceIndex])
        let command = trimmed[trimmed.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
        guard let pid = Int(pidText), !command.isEmpty else { continue }

        commands[pid] = command
    }

    return commands
}

func topMemoryRows(from topOutput: String) -> [TopMemoryRow] {
    var rows: [TopMemoryRow] = []

    for line in topOutput.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 3 else { continue }
        guard let pid = Int(parts[0]) else { continue }
        guard let kilobytes = parseTopMemoryKilobytes(String(parts[parts.count - 1])) else { continue }

        let fallbackName = parts.dropFirst().dropLast().joined(separator: " ")
        rows.append(TopMemoryRow(pid: pid, kilobytes: kilobytes, fallbackName: fallbackName))
    }

    return rows
}

func renderTopMemoryRows(_ rows: [TopMemoryRow], commandByPid: [Int: String], count: Int) -> [String] {
    var kilobytesByName: [String: Int] = [:]

    for row in rows {
        let command = commandByPid[row.pid] ?? row.fallbackName
        let name = appName(from: command)
        kilobytesByName[name, default: 0] += row.kilobytes
    }

    return kilobytesByName
        .map { ProcessMemory(kilobytes: $0.value, name: $0.key) }
        .sorted { $0.kilobytes > $1.kilobytes }
        .prefix(count)
        .map { process in
            "\(process.name) \(formatMemory(kilobytes: process.kilobytes))"
        }
}

func topMemoryUsers(fromTopOutput topOutput: String, psOutput: String, count: Int) -> [String] {
    renderTopMemoryRows(topMemoryRows(from: topOutput), commandByPid: processCommandMap(from: psOutput), count: count)
}

func topMemoryUsers(from psOutput: String, count: Int) -> [String] {
    var processes: [ProcessMemory] = []

    for line in psOutput.split(separator: "\n").dropFirst() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else { continue }

        let rssText = String(trimmed[..<spaceIndex])
        let command = trimmed[trimmed.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
        guard let rssKilobytes = Int(rssText), rssKilobytes > 0 else { continue }

        processes.append(ProcessMemory(kilobytes: rssKilobytes, name: appName(from: command)))
    }

    return processes
        .sorted { $0.kilobytes > $1.kilobytes }
        .prefix(count)
        .map { process in
            "\(process.name) \(formatMemory(kilobytes: process.kilobytes))"
        }
}

func topMemoryUsers(_ count: Int) -> [String] {
    let top = run("/usr/bin/top", ["-l", "1", "-stats", "pid,command,mem", "-o", "mem", "-n", String(max(count * 4, 20))], timeoutMs: 5000)
    if top.exitCode == 0 {
        let rows = topMemoryRows(from: top.stdout)
        let pids = rows.map(\.pid).filter { $0 > 0 }
        let pidList = pids.map(String.init).joined(separator: ",")
        let psCommands = pidList.isEmpty
            ? (stdout: "", exitCode: Int32(1))
            : run("/bin/ps", ["-p", pidList, "-o", "pid=", "-o", "command="], timeoutMs: 3000)

        let commandByPid = psCommands.exitCode == 0 ? processCommandMap(from: psCommands.stdout) : [:]
        let users = renderTopMemoryRows(rows, commandByPid: commandByPid, count: count)
        if !users.isEmpty { return users }
    }

    let raw = run("/bin/ps", ["-axo", "rss,comm"], timeoutMs: 3000).stdout
    return topMemoryUsers(from: raw, count: count)
}

final class NanoMacThrottleApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var thermalState: ThermalState = .unknown
    private var thermalPressure: ThermalPressure = .unknown
    private var darwinAvailable = false
    private var darwinToken: Int32 = 0
    private var thermalStateObserver: NSObjectProtocol?

    private var memoryLevel: MemoryPressureLevel = .normal
    private var memorySource: (any DispatchSourceMemoryPressure)?

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    // Serial queue for building notification bodies (which shell out to ps/top)
    // off the main thread, while preserving notification ordering.
    private let notificationQueue = DispatchQueue(label: "nano-mac-throttle.notify", qos: .utility)

    // Notification mode persists across launches; default preserves prior
    // behavior (notify on everything). Snooze is deliberately in-memory only.
    private static let notificationModeKey = "notificationMode"
    private var notificationMode: NotificationMode = {
        let raw = UserDefaults.standard.string(forKey: NanoMacThrottleApp.notificationModeKey) ?? ""
        return NotificationMode(rawValue: raw) ?? .all
    }() {
        didSet { UserDefaults.standard.set(notificationMode.rawValue, forKey: Self.notificationModeKey) }
    }
    private var snoozeUntil: Date?

    // The snooze deadline if (and only if) it is still in the future.
    private var activeSnoozeDeadline: Date? {
        guard let snoozeUntil, Date() < snoozeUntil else { return nil }
        return snoozeUntil
    }

    // Gate evaluated on the main thread before dispatching a notification.
    private func shouldEmit(_ severity: NotificationSeverity) -> Bool {
        notificationAllowed(severity: severity, mode: notificationMode, snoozed: activeSnoozeDeadline != nil)
    }

    private var shouldShowThermalIcon: Bool {
        darwinAvailable ? thermalPressure.isThrottle : thermalState.isFallbackThrottle
    }

    private var shouldShowIcon: Bool {
        shouldShowThermalIcon || memoryLevel.isPressure
    }

    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.delegate = self
        menu.autoenablesItems = false
        menu.delegate = self

        thermalState = .current()
        if thermalState.isWarm {
            startDarwinMonitoring()
        }
        startMemoryMonitoring()
        updateStatusItemVisibility()

        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleThermalStateChange()
        }
    }

    func showIconTest() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.delegate = self
        menu.autoenablesItems = false
        thermalState = .serious
        thermalPressure = .heavy
        darwinAvailable = true
        memoryLevel = .high
        showStatusItem()
        notifyUser("Nano Mac Throttle test", "Temporary menu bar icon shown for 15 seconds.")

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(15)) {
            NSApplication.shared.terminate(nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        openStatusMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openStatusMenu()
        return false
    }

    @objc private func refreshMenu() {
        thermalState = .current()
        if darwinAvailable {
            thermalPressure = readDarwinPressureFromToken() ?? .unknown
        }
        updateStatusItemVisibility()
        rebuildMenu()
    }

    private func startMemoryMonitoring() {
        guard memorySource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            self?.handleMemoryPressureEvent(source.data)
        }
        source.resume()
        memorySource = source
    }

    private func handleMemoryPressureEvent(_ event: DispatchSource.MemoryPressureEvent) {
        let previous = memoryLevel
        let current = MemoryPressureLevel.fromEvent(event)
        guard current != previous else {
            updateStatusItemVisibility()
            return
        }

        memoryLevel = current
        sendMemoryTransitionNotification(from: previous, to: current)
        updateStatusItemVisibility()
    }

    private func handleThermalStateChange() {
        let previous = thermalState
        let current = ThermalState.current()
        guard current != previous else { return }

        thermalState = current

        if current.isWarm {
            startDarwinMonitoring()
        }

        if current == .nominal && previous.isWarm {
            // Recovery to nominal.
            emitThermalNotification(title: "Mac thermal back to normal", state: currentThermalDisplayLabel())
            stopDarwinMonitoring()
            thermalPressure = .nominal
        } else if current.isWarm && !previous.isWarm {
            // Entering a warm state. notify_register_dispatch delivers no initial
            // callback, so emit the first alert here from the current reading —
            // otherwise a jump straight to serious/critical (which skips fair)
            // would stay silent until the next Darwin level change.
            sendWarmEntryNotification()
        } else if current.isWarm && !darwinAvailable {
            // Warm-to-warm change with no Darwin pressure feed (e.g. fair -> serious).
            sendFallbackThermalTransitionNotification(from: previous, to: current)
        }

        updateStatusItemVisibility()
    }

    private func sendWarmEntryNotification() {
        let title: String
        if darwinAvailable {
            switch thermalPressure {
            case .heavy: title = "Mac CPU throttling"
            case .trapping, .sleeping: title = "Mac thermal alert"
            default: title = "Mac thermal - fair"
            }
        } else {
            switch thermalState {
            case .critical: title = "Mac thermal alert - critical"
            case .serious: title = "Mac thermal alert - serious"
            default: title = "Mac thermal - fair"
            }
        }
        emitThermalNotification(title: title, state: currentThermalDisplayLabel())
    }

    private func startDarwinMonitoring() {
        guard darwinToken == 0 else { return }

        let status = thermalPressureNotificationName.withCString { name in
            c_notify_register_dispatch(name, &darwinToken, DispatchQueue.main) { [weak self] (_: Int32) in
                self?.handleDarwinPressureChange()
            }
        }

        guard status == 0 else {
            darwinAvailable = false
            darwinToken = 0
            return
        }

        darwinAvailable = true
        thermalPressure = readDarwinPressureFromToken() ?? .unknown
        updateStatusItemVisibility()
    }

    private func stopDarwinMonitoring() {
        guard darwinToken != 0 else {
            darwinAvailable = false
            return
        }

        c_notify_cancel(darwinToken)
        darwinToken = 0
        darwinAvailable = false
    }

    private func handleDarwinPressureChange() {
        guard let current = readDarwinPressureFromToken() else {
            darwinAvailable = false
            sendFallbackThermalTransitionNotification(from: .unknown, to: thermalState)
            updateStatusItemVisibility()
            return
        }

        let previous = thermalPressure
        guard current != previous else {
            updateStatusItemVisibility()
            return
        }

        thermalPressure = current
        sendDarwinThermalTransitionNotification(from: previous, to: current)
        updateStatusItemVisibility()
    }

    private func readDarwinPressureFromToken() -> ThermalPressure? {
        guard darwinToken != 0 else { return readDarwinPressureOnce() }

        var state: UInt64 = 0
        let status = c_notify_get_state(darwinToken, &state)
        guard status == 0 else { return nil }
        return ThermalPressure.fromRaw(state)
    }

    private func currentThermalDisplayLabel() -> String {
        thermalDisplayLabel(
            thermalState: thermalState,
            darwinAvailable: darwinAvailable,
            thermalPressure: thermalPressure
        )
    }

    private func updateStatusItemVisibility() {
        if shouldShowIcon {
            showStatusItem()
        } else {
            hideStatusItem()
        }
    }

    private func showStatusItem() {
        guard statusItem == nil else {
            updateStatusItemIcon()
            rebuildMenu()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu
        statusItem = item
        updateStatusItemIcon()
        rebuildMenu()
    }

    private func openStatusMenu() {
        showStatusItem()
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.button?.performClick(nil)
        }
    }

    private func hideStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let description: String
        if shouldShowThermalIcon && memoryLevel.isPressure {
            symbolName = "exclamationmark.triangle"
            description = "Thermal and memory pressure"
        } else if shouldShowThermalIcon {
            symbolName = "thermometer.high"
            description = "Thermal pressure"
        } else {
            symbolName = "memorychip"
            description = "Memory pressure"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "LOAD"
        }
        button.toolTip = "Nano Mac Throttle: \(description)"
    }

    private func rebuildMenu() {
        // Render instantly with placeholders, then gather the process listings
        // (ps/top) off the main thread so opening the menu never blocks the UI.
        // The fetched data replaces the placeholders in place once it arrives.
        renderMenu(topCPUUsers: nil, memoryFree: nil, topMemoryUsers: nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cpu = topCPU(3)
            let memFree = currentMemoryFreePercentage()
            let mem = topMemoryUsers(3)
            DispatchQueue.main.async {
                self?.renderMenu(topCPUUsers: cpu, memoryFree: memFree, topMemoryUsers: mem)
            }
        }
    }

    private func renderMenu(topCPUUsers: [String]?, memoryFree: String?, topMemoryUsers: [String]?) {
        menu.removeAllItems()

        menu.addItem(infoMenuItem(
            "Thermal state : \(currentThermalDisplayLabel())",
            symbolName: "thermometer.high",
            accessibilityDescription: "Thermal state"
        ))
        if let topCPUUsers {
            addTopUsersMenuItems(to: menu, title: "Top CPU users :", users: topCPUUsers, emptyMessage: "no dominant CPU user")
        } else {
            menu.addItem(infoMenuItem("Top CPU users :"))
            menu.addItem(infoMenuItem("  …"))
        }
        menu.addItem(.separator())
        let memorySuffix = memoryFree.map { " (Free = \($0))" } ?? ""
        menu.addItem(infoMenuItem(
            "Memory pressure : \(memoryLevel.label)\(memorySuffix)",
            symbolName: "memorychip",
            accessibilityDescription: "Memory pressure"
        ))
        if let topMemoryUsers {
            addTopUsersMenuItems(to: menu, title: "Top Memory users :", users: topMemoryUsers, emptyMessage: "unavailable")
        } else {
            menu.addItem(infoMenuItem("Top Memory users :"))
            menu.addItem(infoMenuItem("  …"))
        }

        appendNotificationControls(to: menu)
    }

    // Builds the interactive Notifications submenu (mode radios + snooze
    // durations) plus a top-level snooze status line + resume action when a
    // snooze is active. Rebuilt on every render so it survives the async swap.
    private func appendNotificationControls(to menu: NSMenu) {
        menu.addItem(.separator())

        if let deadline = activeSnoozeDeadline {
            let item = infoMenuItem("🔕 Snoozed until \(Self.clockFormatter.string(from: deadline))")
            menu.addItem(item)
            menu.addItem(actionMenuItem("Resume notifications", #selector(resumeNotifications)))
        }

        let notificationsItem = infoMenuItem(
            "Notifications",
            symbolName: "bell",
            accessibilityDescription: "Notification settings"
        )
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for mode in [NotificationMode.all, .important, .off] {
            let item = actionMenuItem(mode.label, #selector(selectMode(_:)))
            item.representedObject = mode.rawValue
            item.state = (mode == notificationMode) ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        for minutes in [30, 60, 180] {
            let item = actionMenuItem(snoozeLabel(minutes: minutes), #selector(snooze(_:)))
            item.representedObject = minutes
            submenu.addItem(item)
        }

        notificationsItem.submenu = submenu
        menu.addItem(notificationsItem)
    }

    private func snoozeLabel(minutes: Int) -> String {
        switch minutes {
        case 30: return "Snooze 30 minutes"
        case 60: return "Snooze 1 hour"
        case 180: return "Snooze 3 hours"
        default: return "Snooze \(minutes) minutes"
        }
    }

    private func actionMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = NotificationMode(rawValue: raw) else { return }
        notificationMode = mode
        rebuildMenu()
    }

    @objc private func snooze(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        snoozeUntil = Date().addingTimeInterval(Double(minutes) * 60.0)
        rebuildMenu()
    }

    @objc private func resumeNotifications() {
        snoozeUntil = nil
        rebuildMenu()
    }

    private func sendDarwinThermalTransitionNotification(from previous: ThermalPressure, to current: ThermalPressure) {
        let title: String?
        if current == .heavy && !previous.isThrottle {
            title = "Mac CPU throttling"
        } else if current == .trapping || current == .sleeping {
            title = "Mac thermal alert"
        } else if current == .nominal && previous.isPressure {
            title = "Mac thermal back to normal"
        } else if current.isThrottle && previous.isThrottle {
            title = "Mac throttle level changed"
        } else {
            title = nil
        }
        guard let title else { return }

        let state = thermalDisplayLabel(thermalState: thermalState, darwinAvailable: true, thermalPressure: current)
        emitThermalNotification(title: title, state: state)
    }

    private func sendFallbackThermalTransitionNotification(from previous: ThermalState, to current: ThermalState) {
        let title: String?
        if current == .serious && !previous.isFallbackThrottle {
            title = "Mac thermal alert - serious"
        } else if current == .critical {
            title = "Mac thermal alert - critical"
        } else if current == .nominal && previous.isWarm {
            title = "Mac thermal back to normal"
        } else if current.isFallbackThrottle && previous.isFallbackThrottle {
            title = "Mac thermal level changed"
        } else {
            title = nil
        }
        guard let title else { return }

        let state = thermalDisplayLabel(thermalState: current, darwinAvailable: darwinAvailable, thermalPressure: thermalPressure)
        emitThermalNotification(title: title, state: state)
    }

    private func sendMemoryTransitionNotification(from previous: MemoryPressureLevel, to current: MemoryPressureLevel) {
        let title: String?
        if current == .medium && !previous.isPressure {
            title = "Mac memory pressure - medium"
        } else if current == .high {
            title = "Mac memory pressure - high"
        } else if current == .normal && previous.isPressure {
            title = "Mac memory pressure back to normal"
        } else if current.isPressure && previous.isPressure {
            title = "Mac memory pressure changed"
        } else {
            title = nil
        }
        guard let title else { return }
        guard shouldEmit(notificationSeverity(forTitle: title)) else { return }

        let level = current.label
        notificationQueue.async {
            let body = memoryNotificationBody(
                level: level,
                freePercentage: currentMemoryFreePercentage(),
                topMemoryUsers: topMemoryUsers(3)
            )
            notifyUser(title, body)
        }
    }

    // Builds the notification body (which shells out to ps/top) off the main
    // thread. All instance state is captured by the caller and passed in as
    // values, so the background closure touches only pure helpers. The mode /
    // snooze gate is evaluated here on the main thread before dispatching.
    private func emitThermalNotification(title: String, state: String) {
        guard shouldEmit(notificationSeverity(forTitle: title)) else { return }
        notificationQueue.async {
            notifyUser(title, thermalNotificationBody(state: state, topCPUUsers: topCPU(3)))
        }
    }
}

func printCPU() {
    let culprits = topCPU(3)
    if culprits.isEmpty {
        print("topCPU: no dominant CPU user")
    } else {
        print("topCPU:")
        for culprit in culprits {
            print("  \(culprit)")
        }
    }
}

func printMemoryUsers() {
    let users = topMemoryUsers(5)
    if users.isEmpty {
        print("topMemory: unavailable")
    } else {
        print("topMemory:")
        for user in users {
            print("  \(user)")
        }
    }
}

func printStatus() {
    let thermalState = ThermalState.current()
    let pressure = thermalState.isWarm ? readDarwinPressureOnce() ?? .unknown : .nominal
    let thermalLabel = thermalDisplayLabel(
        thermalState: thermalState,
        darwinAvailable: thermalState.isWarm && pressure != .unknown,
        thermalPressure: pressure
    )
    print("thermalState:    \(thermalLabel)")
    print("darwinPressure:  \(thermalState.isWarm ? pressure.label : "not monitoring")")
    printCPU()
    print("memoryPressure:  event-driven in agent (this line is not a level; free % below)")
    print(currentMemoryPressureSummary())
    printMemoryUsers()
}

func runSelfTest() {
    let pressureOutput = """
    The system has 123.
    System-wide memory free percentage: 42%
    """
    precondition(memoryFreePercentage(from: pressureOutput) == "42%")
    precondition(memoryPressureSummary(from: pressureOutput) == "free memory: 42%")
    precondition(thermalDisplayLabel(thermalState: .nominal, darwinAvailable: false, thermalPressure: .unknown) == "nominal")
    precondition(thermalDisplayLabel(thermalState: .fair, darwinAvailable: false, thermalPressure: .unknown) == "fair")
    precondition(thermalDisplayLabel(thermalState: .serious, darwinAvailable: false, thermalPressure: .unknown) == "serious")
    precondition(thermalDisplayLabel(thermalState: .serious, darwinAvailable: true, thermalPressure: .heavy) == "heavy")
    precondition(thermalNotificationBody(state: "heavy", topCPUUsers: ["Xcode 188% core / 24% total"]) == """
    Thermal state : heavy
    Top CPU users : Xcode 188% core / 24% total
    """)
    precondition(memoryNotificationBody(level: "high", freePercentage: "18%", topMemoryUsers: ["Docker VM 9.5 GB"]) == """
    Memory pressure : high (Free = 18%)
    Top Memory users : Docker VM 9.5 GB
    """)

    let psOutput = """
      RSS COMM
    1048576 /Applications/Safari.app/Contents/MacOS/Safari
    512000 /usr/bin/python3
    bad /ignored
    """
    let users = topMemoryUsers(from: psOutput, count: 2)
    precondition(users == ["Safari 1.0 GB", "python3 500 MB"])

    let topOutput = """
    PID    COMMAND          MEM
    54889  com.apple.Virtua 9733M
    594    WindowServer     997M
    """
    let psCommands = """
    54889 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
    594 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon
    """
    let topUsers = topMemoryUsers(fromTopOutput: topOutput, psOutput: psCommands, count: 2)
    precondition(topUsers == ["Docker VM 9.5 GB", "WindowServer 997 MB"])

    precondition(ThermalPressure.fromRaw(0) == .nominal)
    precondition(ThermalPressure.fromRaw(2) == .heavy)
    precondition(MemoryPressureLevel.fromEvent(.normal) == .normal)
    precondition(MemoryPressureLevel.fromEvent(.warning) == .medium)
    precondition(MemoryPressureLevel.fromEvent(.critical) == .high)

    // Notification severity classification.
    precondition(notificationSeverity(forTitle: "Mac CPU throttling") == .important)
    precondition(notificationSeverity(forTitle: "Mac thermal alert") == .important)
    precondition(notificationSeverity(forTitle: "Mac thermal alert - serious") == .important)
    precondition(notificationSeverity(forTitle: "Mac thermal alert - critical") == .important)
    precondition(notificationSeverity(forTitle: "Mac memory pressure - high") == .important)
    precondition(notificationSeverity(forTitle: "Mac thermal - fair") == .small)
    precondition(notificationSeverity(forTitle: "Mac memory pressure - medium") == .small)
    precondition(notificationSeverity(forTitle: "Mac throttle level changed") == .small)
    precondition(notificationSeverity(forTitle: "Mac thermal back to normal") == .small)
    precondition(notificationSeverity(forTitle: "Mac memory pressure back to normal") == .small)

    // Mode / snooze gate (nested thresholds; snooze is a total mute).
    precondition(notificationAllowed(severity: .important, mode: .all, snoozed: false))
    precondition(notificationAllowed(severity: .small, mode: .all, snoozed: false))
    precondition(notificationAllowed(severity: .important, mode: .important, snoozed: false))
    precondition(!notificationAllowed(severity: .small, mode: .important, snoozed: false))
    precondition(!notificationAllowed(severity: .important, mode: .off, snoozed: false))
    precondition(!notificationAllowed(severity: .small, mode: .off, snoozed: false))
    precondition(!notificationAllowed(severity: .important, mode: .all, snoozed: true))
    precondition(!notificationAllowed(severity: .small, mode: .all, snoozed: true))

    print("self-test: ok")
}

let args = CommandLine.arguments

if args.contains("--status") {
    printStatus()
    exit(0)
}

if args.contains("--cpu") {
    printCPU()
    exit(0)
}

if args.contains("--memory") {
    printMemoryUsers()
    exit(0)
}

if args.contains("--test") {
    notifyUser("Nano Mac Throttle test", "installed (thermal: \(ThermalState.current().label), \(currentMemoryPressureSummary()))")
    exit(0)
}

let shouldTestTopCPU = args.contains("--test-top-CPU") || args.contains("--test-top-cpu")
let shouldTestTopMemory = args.contains("--test-top-memory")

if shouldTestTopCPU {
    notifyUser(
        "Nano Mac Throttle CPU format test",
        thermalNotificationBody(state: "heavy", topCPUUsers: sampleTopCPUUsers)
    )
}

if shouldTestTopMemory {
    notifyUser(
        "Nano Mac Throttle memory format test",
        memoryNotificationBody(level: "high", freePercentage: "18%", topMemoryUsers: sampleTopMemoryUsers)
    )
}

if shouldTestTopCPU || shouldTestTopMemory {
    exit(0)
}

if args.contains("--show-icon-test") {
    let app = NanoMacThrottleApp()
    app.showIconTest()
    NSApplication.shared.run()
    exit(0)
}

if args.contains("--self-test") {
    runSelfTest()
    exit(0)
}

let app = NanoMacThrottleApp()
app.start()
NSApplication.shared.run()
