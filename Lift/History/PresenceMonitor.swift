import AppKit
import CoreGraphics
import Darwin

/// Decides whether someone is at this Mac. Present means local keyboard or
/// mouse input within the idle limit, the screen awake and unlocked, and no
/// Screen Sharing session. Input that arrives through Screen Sharing never
/// counts: during a session the Mac is away, and after it ends only input
/// newer than the session end makes it present again.
@MainActor
final class PresenceMonitor: NSObject {
    static let didChange = Notification.Name("PresenceMonitor.didChange")

    private static let idleLimit: TimeInterval = 5 * 60
    private static let pollInterval: TimeInterval = 15
    /// `screensharingd` is socket-activated: it runs only while a client is
    /// connected.
    private static let remoteSessionProcesses: Set<String> = ["screensharingd"]

    private(set) var isPresent = false
    /// When `isPresent` last flipped. Going away by idle is dated to the last
    /// local input, not to the poll that noticed it.
    private(set) var changedAt = Date()

    private var timer: Timer?
    private var wasRemote = false
    private var remoteEndedAt: Date?
    private var screensAsleep = false
    private var screenLocked = false

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        timer = Timer.scheduledTimer(timeInterval: Self.pollInterval, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        poll()
    }

    @objc private func screensDidSleep() { screensAsleep = true; poll() }
    @objc private func screensDidWake() { screensAsleep = false; poll() }
    @objc private func screenDidLock() { screenLocked = true; poll() }
    @objc private func screenDidUnlock() { screenLocked = false; poll() }

    @objc private func poll() {
        let now = Date()
        let remote = Self.remoteSessionActive()
        if wasRemote, !remote { remoteEndedAt = now }
        wasRemote = remote

        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let lastInput = now.addingTimeInterval(-idle)
        let inputIsLocal = remoteEndedAt.map { lastInput > $0 } ?? true
        let present = !remote && !screensAsleep && !screenLocked && idle < Self.idleLimit && inputIsLocal

        guard present != isPresent else { return }
        isPresent = present
        changedAt = !present && idle >= Self.idleLimit ? lastInput : now
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Reads the process table with `sysctl`, like `ps`: `proc_name` cannot
    /// see root daemons from a user process.
    private static func remoteSessionActive() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = processes.count * stride
        guard sysctl(&mib, 3, &processes, &size, nil, 0) == 0 else { return false }
        for var process in processes.prefix(size / stride) {
            let name = withUnsafeBytes(of: &process.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if remoteSessionProcesses.contains(name) { return true }
        }
        return false
    }
}
