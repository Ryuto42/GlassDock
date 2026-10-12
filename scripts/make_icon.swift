import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let inset = rect.insetBy(dx: 100, dy: 100)
    let body = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.75, alpha: 1),
    ])!.draw(in: body, angle: -60)

    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: 40, y: 560, width: 940, height: 640)).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let bar = NSRect(x: 190, y: 220, width: 644, height: 170)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSColor.white.withAlphaComponent(0.32).setFill()
    NSBezierPath(roundedRect: bar, xRadius: 70, yRadius: 70).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.7).setStroke()
    let rim = NSBezierPath(roundedRect: bar.insetBy(dx: 2, dy: 2), xRadius: 68, yRadius: 68)
    rim.lineWidth = 4
    rim.stroke()

    let tiles: [(CGFloat, NSColor)] = [(96, .white), (120, .white), (96, .white)]
    var x: CGFloat = 512 - (96 + 120 + 96 + 60) / 2
    for (s, c) in tiles {
        let r = NSRect(x: x, y: 262 + (s == 120 ? 0 : 12), width: s, height: s)
        c.withAlphaComponent(s == 120 ? 0.98 : 0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: s * 0.24, yRadius: s * 0.24).fill()
        x += s + 30
    }
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 512 - 9, y: 234, width: 18, height: 18)).fill()
    return true
}

let out = CommandLine.arguments[1]
let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
