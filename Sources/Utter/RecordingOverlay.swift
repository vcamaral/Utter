import AppKit
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 28

    @Published var levels = [CGFloat](repeating: 0, count: barCount)
    @Published var isTranscribing = false
    @Published var isLocked = false
    /// A short notice shown instead of the waveform.
    @Published var message: String?

    /// Adds the latest microphone RMS, mapped from dB so quiet speech still moves the bars.
    func push(rms: Float) {
        let db = 20 * log10(max(rms, 1e-5))
        let normalized = min(max((db + 55) / 40, 0), 1)
        levels.removeFirst()
        levels.append(CGFloat(normalized))
    }

    func reset() {
        levels = [CGFloat](repeating: 0, count: Self.barCount)
        isTranscribing = false
        isLocked = false
        message = nil
    }
}

/// Floating pill at the bottom of the screen with a live waveform.
/// It never takes focus or mouse clicks, so typing goes on in the app you're dictating into.
@MainActor
final class RecordingOverlay {
    let model = OverlayModel()

    // The panel is fixed and transparent; the pill sits at its bottom.
    private static let size = NSSize(width: 320, height: 80)
    private static let bottomMargin: CGFloat = 28

    private static let messageDuration: TimeInterval = 2.5

    private let panel: NSPanel
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    /// Shows the overlay and keeps sampling `level` to animate the waveform.
    func show(level: @escaping () -> Float) {
        cancelScheduledHide()
        model.reset()
        placeOnActiveScreen()
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.push(rms: level()) }
        }
    }

    func showTranscribing() {
        timer?.invalidate()
        timer = nil
        model.isTranscribing = true
    }

    func showLocked() {
        model.isLocked = true
    }

    /// Shows a notice for a moment, whether or not the overlay was already visible.
    func flash(_ message: String) {
        timer?.invalidate()
        timer = nil
        model.reset()
        model.message = message
        placeOnActiveScreen()
        panel.orderFrontRegardless()
        cancelScheduledHide()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.messageDuration, execute: work)
    }

    func hide() {
        cancelScheduledHide()
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func cancelScheduledHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func placeOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + Self.bottomMargin))
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .animation(.easeOut(duration: 0.2), value: model.isTranscribing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.message {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(height: 26)
        } else {
            HStack(spacing: 10) {
                if model.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Waveform(levels: model.levels)
            }
            .opacity(model.isTranscribing ? 0.35 : 1)
        }
    }
}

private struct Waveform: View {
    let levels: [CGFloat]

    private static let height: CGFloat = 26

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .frame(width: 3, height: max(3, levels[i] * Self.height))
            }
        }
        .frame(height: Self.height)
        .foregroundStyle(.white)
        .animation(.linear(duration: 1.0 / 30), value: levels)
    }
}
