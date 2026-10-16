import AppKit

/// The app icon's waveform, drawn as a monochrome menu bar icon. It's a template image, so macOS
/// colors it for light and dark menu bars, and it can be tinted (red while recording).
enum MenuBarIcon {
    /// Five bars instead of the app icon's seven: seven don't fit legibly in 18 points.
    private static let bars: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    static let normal = make(alpha: 1)
    /// While transcribing: same shape, faded, so it reads as "busy" without a different icon.
    static let dimmed = make(alpha: 0.4)

    private static func make(alpha: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let barWidth: CGFloat = 2.2
            let gap: CGFloat = 1.8
            let maxHeight: CGFloat = 14
            let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
            NSColor.black.withAlphaComponent(alpha).setFill()
            for (i, relative) in bars.enumerated() {
                let height = maxHeight * relative
                let x = rect.midX - total / 2 + CGFloat(i) * (barWidth + gap)
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Utter"
        return image
    }
}
