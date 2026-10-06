// Renders the iPhone/iPad app icon (run from the repo root: swift iOS/scripts/make-icon.swift).
// Same artwork as scripts/make-icon.swift (the Mac icon), but full-bleed and opaque: iOS applies its own mask.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let output = root.appendingPathComponent("iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

let px = 1024
let s = CGFloat(px)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = CGRect(x: 0, y: 0, width: s, height: s)
let gradient = NSGradient(colors: [
    NSColor(red: 0.02, green: 0.06, blue: 0.16, alpha: 1),
    NSColor(red: 0.05, green: 0.20, blue: 0.42, alpha: 1),
    NSColor(red: 0.00, green: 0.62, blue: 0.86, alpha: 1),
])!
gradient.draw(in: body, angle: 65)

// Soft highlight.
let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
glow.draw(in: NSBezierPath(ovalIn: body.insetBy(dx: -body.width * 0.2, dy: body.height * 0.15).offsetBy(dx: 0, dy: body.height * 0.45)),
          relativeCenterPosition: .zero)

// Glyph: a screen with a play triangle (the Mac glyph's proportions within the full square).
let screen = CGRect(x: s * 0.22, y: s * 0.32, width: s * 0.56, height: s * 0.39)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: screen.height * 0.16, yRadius: screen.height * 0.16)
NSColor.white.withAlphaComponent(0.95).setStroke()
screenPath.lineWidth = s * 0.042
screenPath.stroke()
let stand = NSBezierPath(roundedRect: CGRect(x: body.midX - s * 0.12, y: s * 0.225, width: s * 0.24, height: s * 0.042),
                         xRadius: s * 0.02, yRadius: s * 0.02)
NSColor.white.withAlphaComponent(0.95).setFill()
stand.fill()
let tri = NSBezierPath()
let c = CGPoint(x: screen.midX + screen.width * 0.03, y: screen.midY)
let r = screen.height * 0.24
tri.move(to: CGPoint(x: c.x - r * 0.75, y: c.y + r))
tri.line(to: CGPoint(x: c.x + r, y: c.y))
tri.line(to: CGPoint(x: c.x - r * 0.75, y: c.y - r))
tri.close()
tri.fill()

NSGraphicsContext.restoreGraphicsState()

// iOS icons must be opaque: flatten into an RGB bitmap without an alpha channel.
let flat = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
flat.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: px, height: px))
try NSBitmapImageRep(cgImage: flat.makeImage()!).representation(using: .png, properties: [:])!.write(to: output)
print(output.path)
