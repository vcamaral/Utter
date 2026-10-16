import AppKit
import SwiftUI

/// Small window that asks you to press the key you want to hold to dictate.
@MainActor
final class TriggerCapturePanel {
    var onCapture: (Trigger) -> Void = { _ in }
    var onClose: () -> Void = {}

    /// Modifier keys that are refused with an explanation (Left ⇧, Right ⇧, Left ⌘), with their device masks.
    private static let refusedKeys: [UInt16: UInt] = [56: 0x02, 60: 0x04, 55: 0x08]

    private let model = CaptureModel()
    private var window: NSWindow?
    private var monitor: Any?

    func show(current: Trigger) {
        model.message = "Current: \(current.name)"
        model.isError = false
        model.captured = nil
        if window == nil {
            let hosting = NSHostingController(rootView: CaptureView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Dictation Key"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopListening() }
            }
            self.window = window
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startListening()
    }

    private func startListening() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil   // swallow, so the window doesn't beep or react
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onClose()
    }

    private func handle(_ event: NSEvent) {
        guard model.captured == nil else { return }
        if event.type == .keyDown {
            if event.keyCode == 53 {   // Esc
                window?.close()
            } else {
                refuse("Use a modifier key. Other keys would also type in the app you're dictating into.")
            }
            return
        }
        // flagsChanged fires on press and on release; only the press counts.
        let flags = event.modifierFlags.rawValue
        guard let trigger = Trigger(keyCode: event.keyCode) else {
            if let mask = Self.refusedKeys[event.keyCode], flags & mask != 0 {
                refuse("⇧ and Left ⌘ are used while typing and in shortcuts, so they'd start dictation all the time. Try ⌥, ⌃, Right ⌘ or fn.")
            }
            return
        }
        guard flags & trigger.flagMask != 0 else { return }
        model.captured = trigger
        model.message = "Hold \(trigger.name) to dictate"
        model.isError = false
        onCapture(trigger)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.window?.close()
        }
    }

    private func refuse(_ message: String) {
        NSSound.beep()
        model.message = message
        model.isError = true
    }
}

@MainActor
private final class CaptureModel: ObservableObject {
    @Published var message = ""
    @Published var isError = false
    @Published var captured: Trigger?
}

private struct CaptureView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: model.captured == nil ? "keyboard" : "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(model.captured == nil ? Color.secondary : Color.green)
            Text(model.captured == nil ? "Press the key you want to hold to dictate" : "Done")
                .font(.headline)
            Text(model.message)
                .font(.callout)
                .foregroundStyle(model.isError ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Esc to cancel")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 340)
    }
}
