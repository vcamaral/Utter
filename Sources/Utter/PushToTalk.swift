import AppKit

/// Turns presses of the trigger key into dictation events. Two ways to dictate:
/// - Hold: hold the key while you speak, release to finish.
/// - Hands-free: double-tap to start, tap once more to finish (Esc cancels).
///
/// Recording starts on the very first press, so no word is lost while it's still unclear which
/// of the two it is, or whether it was an accidental tap. Feedback (overlay, sound, pausing music)
/// waits for `onCommit`, so taps and ⌥-shortcuts don't make the screen flicker or the music stutter.
///
/// Needs Accessibility permission to see keys pressed while other apps are in front.
@MainActor
final class PushToTalk {
    var onStart: () -> Void = {}
    /// The recording is intentional: held long enough, or locked hands-free.
    var onCommit: () -> Void = {}
    var onLock: () -> Void = {}
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Ignores the trigger, e.g. while a new one is being chosen.
    var isPaused = false

    /// Shorter presses are taps: either the first half of a double-tap, or accidental.
    private static let minimumHold: TimeInterval = 0.3
    /// How long after a tap a second press still counts as a double-tap.
    private static let doubleTapWindow: TimeInterval = 0.35
    private static let escapeKeyCode: UInt16 = 53

    private enum Phase {
        case idle
        case holding(since: Date)
        /// Released quickly; waiting to see whether a second press follows.
        case tapped
        /// Hands-free. `awaitingRelease` is true until the press that locked it is released.
        case locked(awaitingRelease: Bool)
    }

    private let settings: AppSettings
    private var monitors: [Any] = []
    private var phase = Phase.idle
    private var pendingWork: DispatchWorkItem?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func install() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Forgets the current press, e.g. when the app ended a hands-free dictation by itself.
    func reset() {
        cancelPending()
        phase = .idle
    }

    // MARK: - Private

    private func handle(_ event: NSEvent) {
        guard !isPaused else { return }
        let trigger = settings.trigger
        switch event.type {
        case .flagsChanged where event.keyCode == trigger.keyCode:
            let isDown = event.modifierFlags.rawValue & trigger.flagMask != 0
            isDown ? triggerDown() : triggerUp()
        case .keyDown:
            otherKeyDown(event.keyCode)
        default:
            break
        }
    }

    private func triggerDown() {
        switch phase {
        case .idle:
            phase = .holding(since: Date())
            onStart()
            schedule(after: Self.minimumHold) { [weak self] in
                guard let self, case .holding = phase else { return }
                onCommit()
            }
        case .tapped:
            phase = .locked(awaitingRelease: true)
            cancelPending()
            onCommit()
            onLock()
        case .locked(awaitingRelease: false):
            finish(with: onStop)
        case .holding, .locked(awaitingRelease: true):
            break
        }
    }

    private func triggerUp() {
        switch phase {
        case .holding(let since):
            if Date().timeIntervalSince(since) >= Self.minimumHold {
                finish(with: onStop)
            } else {
                phase = .tapped
                schedule(after: Self.doubleTapWindow) { [weak self] in
                    guard let self, case .tapped = phase else { return }
                    finish(with: onCancel)
                }
            }
        case .locked(awaitingRelease: true):
            phase = .locked(awaitingRelease: false)
        case .idle, .tapped, .locked(awaitingRelease: false):
            break
        }
    }

    private func otherKeyDown(_ keyCode: UInt16) {
        switch phase {
        case .holding, .tapped:
            // The key is being used as a modifier to type or for a shortcut (e.g. ⌥E, ⌘C), not to dictate.
            finish(with: onCancel)
        case .locked where keyCode == Self.escapeKeyCode:
            finish(with: onCancel)
        case .idle, .locked:
            break
        }
    }

    private func finish(with callback: () -> Void) {
        cancelPending()
        phase = .idle
        callback()
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        cancelPending()
        let item = DispatchWorkItem(block: work)
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
    }
}
