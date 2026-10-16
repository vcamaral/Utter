// Generates Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift [preview.png]
import AppKit

/// Relative heights of the waveform bars, symmetric around the center.
let bars: [CGFloat] = [0.28, 0.52, 0.80, 1.00, 0.80, 0.52, 0.28]

func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 content area, ~185/1024 corner radius.
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Warm diagonal gradient, from the top-left corner down to the bottom-right.
    NSGradient(colors: [
        NSColor(red: 1.00, green: 0.62, blue: 0.36, alpha: 1),
        NSColor(red: 0.98, green: 0.30, blue: 0.56, alpha: 1),
        NSColor(red: 0.62, green: 0.36, blue: 1.00, alpha: 1),
    ])!.draw(in: shape, angle: -45)

    // Waveform: white rounded bars.
    let barWidth = 64 * s
    let gap = 34 * s
    let maxHeight = 520 * s
    let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    let wave = NSBezierPath()
    for (i, height) in bars.enumerated() {
        let h = maxHeight * height
        let x = rect.midX - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
        wave.append(NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h),
                                 xRadius: barWidth / 2, yRadius: barWidth / 2))
    }
    NSColor.white.setFill()
    wave.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 1 {
    try! render(size: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    exit(0)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "OK: Resources/AppIcon.icns" : "iconutil failed")
