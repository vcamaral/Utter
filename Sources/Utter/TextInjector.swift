import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Types text into the frontmost app by pasting it.
/// Requires Accessibility permission (System Settings → Privacy & Security).
@MainActor
enum TextInjector {
    enum Outcome {
        case pasted
        /// There was nowhere to paste: the text was left on the clipboard instead.
        case copied
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// What System Settings calls this permission: macOS 27 renamed Accessibility.
    static let permissionName = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        ? "Device Control and Data Access" : "Accessibility"

    /// Opens the settings pane where Utter is switched on. No macOS prompt in between: asking whether the app
    /// is trusted is enough to put it in that list (switched off), so it's already there waiting.
    static func requestPermission() {
        _ = AXIsProcessTrusted()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func insert(_ text: String) -> Outcome {
        // Utter's own windows (the setup's "Try it" box): insert directly. Asking Accessibility about
        // our own process from the main thread would wait on itself until it times out.
        if NSApp.isActive {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return copyOnly(text) }
            textView.insertText(text, replacementRange: textView.selectedRange())
            return .pasted
        }
        switch focusedTarget() {
        case .textField(let element):
            paste(needsLeadingSpace(before: element) ? " " + text : text, restoreClipboard: true)
            return .pasted
        case .unknown:
            // Can't confirm the paste landed (many Electron apps and terminals don't say what's
            // focused), so the text stays on the clipboard too: never lose a dictation.
            paste(text, restoreClipboard: false)
            return .pasted
        case .nothing:
            return copyOnly(text)
        }
    }

    private static func copyOnly(_ text: String) -> Outcome {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .copied
    }

    // MARK: - Focus

    private enum Target {
        case textField(AXUIElement)
        case unknown
        case nothing
    }

    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
    /// Focused elements that clearly can't take text (Finder file lists, buttons…).
    private static let nonTextRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXSliderRole, kAXImageRole, kAXListRole, kAXOutlineRole, kAXTableRole, kAXBrowserRole,
    ]

    private static func focusedTarget() -> Target {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value)
        if error == .noValue { return .nothing }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown }
        let element = value as! AXUIElement

        let role = string(kAXRoleAttribute, of: element)
        if string(kAXSubroleAttribute, of: element) == kAXSecureTextFieldSubrole { return .nothing }   // password field
        if let role, textRoles.contains(role) { return .textField(element) }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .textField(element)
        }
        if let role, nonTextRoles.contains(role) { return .nothing }
        return .unknown
    }

    /// True when the character before the cursor is a letter, digit or punctuation, so a second
    /// dictation doesn't stick to the end of the first ("one.Two").
    private static func needsLeadingSpace(before element: AXUIElement) -> Bool {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return false }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location > 0 else { return false }

        var previous = CFRange(location: selection.location - 1, length: 1)
        guard let previousValue = AXValueCreate(.cfRange, &previous) else { return false }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         previousValue, &result) == .success,
              let character = (result as? String)?.unicodeScalars.first
        else { return false }

        return !CharacterSet.whitespacesAndNewlines.contains(character) && !"([{\"'“‘/".unicodeScalars.contains(character)
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Paste

    private static func paste(_ text: String, restoreClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if restoreClipboard {
            // Asks clipboard managers not to record the dictation as a copy.
            item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount

        postKey(kVK_ANSI_V, flags: .maskCommand)

        guard restoreClipboard else { return }
        // Give the target app time to read the clipboard before putting the old content back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pasteboard.changeCount == ours else { return }   // something else copied meanwhile
            restore(saved, to: pasteboard)
        }
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func postKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
