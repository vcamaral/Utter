import AppKit
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 9
    /// The latest level sits in the center bar and older ones ripple out to the sides.
    private static let historyLength = barCount / 2 + 1
    /// Bars are taller in the middle, like a voice.
    private static let profile: [CGFloat] = [0.45, 0.6, 0.75, 0.9, 1, 0.9, 0.75, 0.6, 0.45]

    @Published private(set) var bars = [CGFloat](repeating: 0, count: barCount)
    @Published var isTranscribing = false
    /// When hands-free started; `nil` while holding the key.
    @Published var lockedSince: Date?
    /// How to stop hands-free, e.g. "tap Right ⌘ to finish · esc to cancel".
    @Published var lockedHint = ""
    /// A short notice shown instead of the waveform.
    @Published var message: String?
    @Published var isError = false

    private var history = [CGFloat](repeating: 0, count: historyLength)

    /// Adds the latest microphone RMS, mapped from dB so quiet speech still moves the bars.
    func push(rms: Float) {
        let db = 20 * log10(max(rms, 1e-5))
        history.insert(CGFloat(min(max((db + 55) / 40, 0), 1)), at: 0)
        history.removeLast()
        let center = Self.barCount / 2
        bars = (0..<Self.barCount).map { history[abs($0 - center)] * Self.profile[$0] }
    }

    func reset() {
        history = [CGFloat](repeating: 0, count: Self.historyLength)
        bars = [CGFloat](repeating: 0, count: Self.barCount)
        isTranscribing = false
        lockedSince = nil
        message = nil
        isError = false
    }
}

/// Floating pill at the bottom of the screen: a small waveform while listening, a moving wave
/// while transcribing, and short notices. It never takes focus or mouse clicks, so typing goes on
/// in the app you're dictating into.
@MainActor
final class RecordingOverlay {
    let model = OverlayModel()

    // The panel is fixed and transparent; the pill sits at its bottom.
    private static let size = NSSize(width: 420, height: 90)
    private static let bottomMargin: CGFloat = 28

    private static let messageDuration: TimeInterval = 2.5
    private static let errorDuration: TimeInterval = 4

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

    func showLocked(hint: String) {
        model.lockedSince = Date()
        model.lockedHint = hint
    }

    /// Shows a notice for a moment, whether or not the overlay was already visible.
    /// Errors always show, even with the indicator turned off: otherwise a failure looks like nothing happened.
    func flash(_ message: String, isError: Bool = false) {
        timer?.invalidate()
        timer = nil
        model.reset()
        model.message = message
        model.isError = isError
        placeOnActiveScreen()
        panel.orderFrontRegardless()
        cancelScheduledHide()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? Self.errorDuration : Self.messageDuration), execute: work)
    }

    func hide() {
        cancelScheduledHide()
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        // Also stops the hands-free clock and the transcribing wave, which would keep redrawing while hidden.
        model.reset()
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .animation(.easeOut(duration: 0.2), value: model.isTranscribing)
            .animation(.easeOut(duration: 0.2), value: model.lockedSince)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.message {
            HStack(spacing: 8) {
                if model.isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                Text(message)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .font(.system(size: 13, weight: .medium))
            .frame(minHeight: 22)
        } else if let since = model.lockedSince {
            VStack(spacing: 5) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    waveform
                    // Hands-free can run long: show for how long it's been listening.
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 36, alignment: .trailing)
                }
                if !model.isTranscribing {
                    Text(model.lockedHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        } else {
            waveform
        }
    }

    @ViewBuilder
    private var waveform: some View {
        if model.isTranscribing {
            ProcessingWave()
        } else {
            Waveform(bars: model.bars)
        }
    }
}

private enum Bars {
    static let width: CGFloat = 4
    static let spacing: CGFloat = 4
    static let maxHeight: CGFloat = 22
}

/// Listening: bars that follow your voice, quiet dots in silence.
private struct Waveform: View {
    let bars: [CGFloat]

    var body: some View {
        HStack(spacing: Bars.spacing) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule().frame(width: Bars.width, height: max(Bars.width, bars[i] * Bars.maxHeight))
            }
        }
        .frame(height: Bars.maxHeight)
        .foregroundStyle(.white)
        .animation(.linear(duration: 1.0 / 30), value: bars)
    }
}

/// Transcribing: a wave running through the bars, so it reads as "working", not "stuck".
private struct ProcessingWave: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: Bars.spacing) {
                ForEach(0..<OverlayModel.barCount, id: \.self) { i in
                    let phase = (sin(time * 7 - Double(i) * 0.7) + 1) / 2
                    Capsule().frame(width: Bars.width, height: Bars.width + CGFloat(phase) * Bars.maxHeight * 0.5)
                }
            }
            .frame(height: Bars.maxHeight)
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}
