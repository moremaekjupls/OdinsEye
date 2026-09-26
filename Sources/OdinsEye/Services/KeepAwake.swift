import AppKit
import IOKit.pwr_mgt

/// "Не спать": keeps the Mac awake the way `caffeinate` does — a power
/// assertion held for as long as the mode is on. No permission, no root.
///
/// Two kinds of assertion, one at a time: `PreventUserIdleDisplaySleep` keeps
/// the screen lit (and with it the system), `PreventUserIdleSystemSleep` only
/// the system, letting the display dim and sleep as usual. Both show up in
/// `pmset -g assertions` under the name below while held.
///
/// What it cannot do: a closed lid on battery with no external display still
/// sleeps. That is clamshell sleep, decided below the assertion level.
///
/// The chosen duration and display option are remembered in `config.json`;
/// the mode itself is not — every launch starts with it off.
@MainActor
final class KeepAwake: ObservableObject {
    enum Duration: String, CaseIterable, Identifiable {
        case indefinite, oneHour, twoHours, fourHours

        var id: String { rawValue }

        var seconds: TimeInterval? {
            switch self {
            case .indefinite: return nil
            case .oneHour: return 3600
            case .twoHours: return 2 * 3600
            case .fourHours: return 4 * 3600
            }
        }

        /// Full name, for the menu.
        var title: String {
            switch self {
            case .indefinite: return localized("Indefinitely")
            case .oneHour: return localized("1 Hour")
            case .twoHours: return localized("2 Hours")
            case .fourHours: return localized("4 Hours")
            }
        }

        /// Short name, for the chips in Settings.
        var shortTitle: String {
            switch self {
            case .indefinite: return "∞"
            case .oneHour: return localized("1 h")
            case .twoHours: return localized("2 h")
            case .fourHours: return localized("4 h")
            }
        }
    }

    /// What `pmset -g assertions` lists the assertion as.
    static let assertionName = "Odin's Eye: Не спать"

    @Published private(set) var isActive = false
    /// When a timed mode ends; nil while off or indefinite.
    @Published private(set) var endsAt: Date?

    /// Last chosen duration — what the panel button and the menu toggle start.
    @Published var duration: Duration {
        didSet {
            guard duration != oldValue else { return }
            ConfigStore.shared.keepAwakeDuration = duration.rawValue
        }
    }

    /// Keep the display on as well, or only the system. Changing it while on
    /// swaps the assertion in place and keeps the time left.
    @Published var keepsDisplayOn: Bool {
        didSet {
            guard keepsDisplayOn != oldValue else { return }
            ConfigStore.shared.keepAwakeDisplay = keepsDisplayOn
            if isActive { acquire() }
        }
    }

    private var assertion = IOPMAssertionID(0)
    private var holdsAssertion = false
    private var timer: Timer?

    init() {
        duration = Duration(rawValue: ConfigStore.shared.keepAwakeDuration) ?? .indefinite
        keepsDisplayOn = ConfigStore.shared.keepAwakeDisplay
    }

    // MARK: - Switching

    /// On with the last chosen duration, or off.
    func toggle() {
        if isActive { stop() } else { start(duration) }
    }

    /// Starts — or restarts, with a fresh clock — for this long.
    func start(_ duration: Duration) {
        self.duration = duration
        guard acquire() else { return }
        isActive = true
        timer?.invalidate()
        timer = nil
        if let seconds = duration.seconds {
            let end = Date().addingTimeInterval(seconds)
            endsAt = end
            // A fire date, not an interval: after the Mac was asleep anyway
            // (lid closed), the timer fires on wake if the time has passed.
            let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            endsAt = nil
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        release()
        isActive = false
        endsAt = nil
    }

    /// Time left of a timed mode, nil when off or indefinite.
    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard isActive, let endsAt else { return nil }
        return max(0, endsAt.timeIntervalSince(now))
    }

    /// "1:23" for a timed mode, "∞" for an indefinite one, nil when off.
    func remainingText(at now: Date = Date()) -> String? {
        guard isActive else { return nil }
        guard let left = remaining(at: now) else { return "∞" }
        // Rounded up: "0:00" while still on would read as already off.
        let minutes = Int((left / 60).rounded(.up))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Assertion

    /// Takes the assertion of the current kind, replacing one already held.
    /// The new one is taken before the old one goes, so there is no gap.
    @discardableResult
    private func acquire() -> Bool {
        let type = keepsDisplayOn ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            NSLog("OdinsEye: IOPMAssertionCreateWithName failed: \(result)")
            return false
        }
        release()
        assertion = id
        holdsAssertion = true
        return true
    }

    private func release() {
        guard holdsAssertion else { return }
        IOPMAssertionRelease(assertion)
        holdsAssertion = false
        assertion = IOPMAssertionID(0)
    }
}
