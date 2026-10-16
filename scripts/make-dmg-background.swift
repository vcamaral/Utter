// Draws the DMG window background. Usage: swift scripts/make-dmg-background.swift <out.png> <scale>
// Layout matches scripts/dmg-settings.py: 600x400 window, app icon at (150, 190), Applications at (450, 190).
import AppKit

let scale = CGFloat(Double(CommandLine.arguments[2])!)
let width: CGFloat = 600, height: CGFloat = 400
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                    bytesPerRow: 0, space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Soft light background.
let bg = CGGradient(colorsSpace: rgb, colors: [color(0xfafafc), color(0xeceef3)] as CFArray, locations: nil)!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

// Arrow between the two icons (Finder positions are top-left based; CG is bottom-left).
let arrowY = height - 190
let shaft = CGMutablePath()
shaft.move(to: CGPoint(x: 245, y: arrowY))
shaft.addLine(to: CGPoint(x: 340, y: arrowY))
let head = CGMutablePath()
head.move(to: CGPoint(x: 328, y: arrowY + 14))
head.addLine(to: CGPoint(x: 352, y: arrowY))
head.addLine(to: CGPoint(x: 328, y: arrowY - 14))
ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(7)
ctx.setStrokeColor(color(0xf24d8f))
ctx.addPath(shaft); ctx.strokePath()
ctx.addPath(head); ctx.strokePath()

// Instruction text.
let text = NSAttributedString(string: "Drag Utter to Applications to install", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.35, green: 0.36, blue: 0.4, alpha: 1),
])
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let textSize = text.size()
text.draw(at: NSPoint(x: (width - textSize.width) / 2, y: 70))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
rep.size = NSSize(width: width, height: height)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
