import AppKit
import ServiceManagement

/// The key you hold to dictate. Only modifier keys: they can be held without typing anything,
/// and Utter watches the keyboard without intercepting it, so any other key would also reach the app in front.
struct Trigger: Equatable {
    let keyCode: UInt16
    let name: String
    /// Bit in `NSEvent.modifierFlags` that tells this specific key is down. The left/right ones are
    /// IOKit's device-dependent masks (NX_DEVICE*KEYMASK), so the other side of the keyboard doesn't interfere.
    let flagMask: UInt

    static let `default` = Trigger(keyCode: 54)!

    private static let accepted: [UInt16: (name: String, mask: UInt)] = [
        61: ("Right ⌥", 0x40),
        58: ("Left ⌥", 0x20),
        54: ("Right ⌘", 0x10),
        62: ("Right ⌃", 0x2000),
        59: ("Left ⌃", 0x01),
        63: ("fn", NSEvent.ModifierFlags.function.rawValue),
    ]

    init?(keyCode: UInt16) {
        guard let key = Self.accepted[keyCode] else { return nil }
        self.keyCode = keyCode
        self.name = key.name
        self.flagMask = key.mask
    }
}

@MainActor
final class AppSettings {
    private let defaults = UserDefaults.standard

    var trigger: Trigger {
        didSet { defaults.set(Int(trigger.keyCode), forKey: "triggerKeyCode") }
    }
    var showIndicator: Bool {
        didSet { defaults.set(showIndicator, forKey: "showIndicator") }
    }
    var pauseMedia: Bool {
        didSet { defaults.set(pauseMedia, forKey: "pauseMedia") }
    }
    var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: "playSounds") }
    }
    /// Set once the first-run setup was finished, so it doesn't open on every launch.
    var setupCompleted: Bool {
        didSet { defaults.set(setupCompleted, forKey: "setupCompleted") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    init() {
        let keyCode = (defaults.object(forKey: "triggerKeyCode") as? Int).map(UInt16.init)
        trigger = keyCode.flatMap(Trigger.init) ?? .default
        showIndicator = defaults.object(forKey: "showIndicator") as? Bool ?? true
        pauseMedia = defaults.object(forKey: "pauseMedia") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        setupCompleted = defaults.bool(forKey: "setupCompleted")
    }
}
