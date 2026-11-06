// Renders the app icon: a terracotta squircle with two overlapping ivory speech bubbles.
import AppKit

let size: CGFloat = 1024
let ivory = NSColor(srgbRed: 0.980, green: 0.976, blue: 0.961, alpha: 1)
let terracotta = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

/// Rounded-rectangle bubble with a short curved tail at the bottom-left (or bottom-right).
func bubble(_ rect: NSRect, radius: CGFloat, tailRight: Bool) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    // Build the tail for the left side, then mirror it if needed. It starts inside the bubble so there is no seam.
    let base = rect.minY, w: CGFloat = 96, x0 = rect.minX + radius * 0.55
    let tip = NSPoint(x: rect.minX + 30, y: base - 78)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: x0, y: base + 40))
    tail.line(to: NSPoint(x: x0, y: base))
    tail.curve(to: tip, controlPoint1: NSPoint(x: x0, y: base - 36), controlPoint2: NSPoint(x: tip.x + 30, y: tip.y + 24))
    tail.curve(to: NSPoint(x: x0 + w, y: base), controlPoint1: NSPoint(x: tip.x + 60, y: tip.y + 10), controlPoint2: NSPoint(x: x0 + w * 0.55, y: base - 4))
    tail.line(to: NSPoint(x: x0 + w, y: base + 40))
    tail.close()
    if tailRight {
        var t = AffineTransform(translationByX: rect.midX, byY: 0)
        t.scale(x: -1, y: 1)
        t.translate(x: -rect.midX, y: 0)
        tail.transform(using: t)
        path.append(tail.reversed)  // mirroring flips the winding; restore it so the union fills
    } else {
        path.append(tail)
    }
    path.windingRule = .nonZero
    return path
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Squircle background with a soft top-to-bottom gradient and a drop shadow, macOS icon grid proportions.
let inset: CGFloat = 100
let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                      xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
terracotta.setFill()
bg.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(srgbRed: 0.902, green: 0.545, blue: 0.420, alpha: 1),
           ending: NSColor(srgbRed: 0.776, green: 0.380, blue: 0.247, alpha: 1))!.draw(in: bg, angle: -90)

// Back bubble: translucent ivory, upper left.
let back = bubble(NSRect(x: 232, y: 470, width: 400, height: 300), radius: 92, tailRight: false)
ivory.withAlphaComponent(0.42).setFill()
back.fill()

// Front bubble: solid ivory, lower right, overlapping the back one.
NSGraphicsContext.saveGraphicsState()
let s2 = NSShadow()
s2.shadowColor = NSColor(srgbRed: 0.45, green: 0.18, blue: 0.10, alpha: 0.35)
s2.shadowOffset = NSSize(width: 0, height: -10)
s2.shadowBlurRadius = 24
s2.set()
let front = bubble(NSRect(x: 392, y: 300, width: 400, height: 300), radius: 92, tailRight: true)
ivory.setFill()
front.fill()
NSGraphicsContext.restoreGraphicsState()

// Two lines of "text" in the front bubble.
terracotta.setFill()
NSBezierPath(roundedRect: NSRect(x: 470, y: 470, width: 244, height: 40), xRadius: 20, yRadius: 20).fill()
terracotta.withAlphaComponent(0.55).setFill()
NSBezierPath(roundedRect: NSRect(x: 470, y: 392, width: 168, height: 40), xRadius: 20, yRadius: 20).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
