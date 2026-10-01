// Renders Resources/AppIcon.icns (run: swift scripts/make-icon.swift).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a continuous-corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()

    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(red: 0.02, green: 0.06, blue: 0.16, alpha: 1),
        NSColor(red: 0.05, green: 0.20, blue: 0.42, alpha: 1),
        NSColor(red: 0.00, green: 0.62, blue: 0.86, alpha: 1),
    ])!
    gradient.draw(in: body, angle: 65)

    // Soft highlight.
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    glow.draw(in: NSBezierPath(ovalIn: body.insetBy(dx: -body.width * 0.2, dy: body.height * 0.15).offsetBy(dx: 0, dy: body.height * 0.45)), relativeCenterPosition: .zero)

    // Glyph: a screen with a play triangle.
    let screen = CGRect(x: body.minX + body.width * 0.20, y: body.minY + body.height * 0.30, width: body.width * 0.60, height: body.height * 0.42)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: screen.height * 0.16, yRadius: screen.height * 0.16)
    NSColor.white.withAlphaComponent(0.95).setStroke()
    screenPath.lineWidth = body.width * 0.045
    screenPath.stroke()
    let stand = NSBezierPath(roundedRect: CGRect(x: body.midX - body.width * 0.13, y: body.minY + body.height * 0.20, width: body.width * 0.26, height: body.height * 0.045),
                             xRadius: body.height * 0.02, yRadius: body.height * 0.02)
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
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(iconset.path)
