import AppKit

// Build-time vector artwork, rendered locally; the application has no asset downloads.
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let outline = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.64, blue: 0.59, alpha: 1),
           ending: NSColor(calibratedRed: 0.025, green: 0.23, blue: 0.34, alpha: 1))!.draw(in: outline, angle: -55)
NSColor.white.setStroke()
let cable = NSBezierPath()
cable.move(to: NSPoint(x: 280, y: 380)); cable.line(to: NSPoint(x: 280, y: 510))
cable.curve(to: NSPoint(x: 512, y: 640), controlPoint1: NSPoint(x: 280, y: 680), controlPoint2: NSPoint(x: 512, y: 470))
cable.curve(to: NSPoint(x: 744, y: 510), controlPoint1: NSPoint(x: 512, y: 810), controlPoint2: NSPoint(x: 744, y: 680))
cable.line(to: NSPoint(x: 744, y: 380)); cable.lineWidth = 44; cable.lineCapStyle = .round; cable.stroke()
for x in [CGFloat(214), CGFloat(678)] {
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 285, width: 132, height: 138), xRadius: 24, yRadius: 24).fill()
    NSColor(calibratedRed: 0.05, green: 0.4, blue: 0.44, alpha: 1).setFill()
    for offset in [CGFloat(34), CGFloat(76)] {
        NSBezierPath(roundedRect: NSRect(x: x + offset, y: 312, width: 22, height: 38), xRadius: 4, yRadius: 4).fill()
    }
}
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
