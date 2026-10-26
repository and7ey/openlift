import AppKit

// Draws the OpenLift app icon: two overlapping file panes and a transfer
// arrow on an indigo gradient. Run from the repository root:
//
//   swift Scripts/make-icon.swift
//
// The generated 1024 px PNG is then sliced into Resources/OpenLift.icns by
// Scripts/make-icon.sh.

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not allocate icon bitmap")
}
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let full = NSRect(x: 0, y: 0, width: size, height: size)

// Background: indigo gradient with a soft inner glow.
let background = NSBezierPath(
    roundedRect: full.insetBy(dx: 10, dy: 10),
    xRadius: 224,
    yRadius: 224
)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.52, alpha: 1),
    NSColor(calibratedRed: 0.34, green: 0.18, blue: 0.72, alpha: 1)
])!
gradient.draw(in: background, angle: -55)

// Two panes: the left one solid, the right one recessed.
func pane(_ rect: NSRect, alpha: CGFloat) {
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 42, yRadius: 42).fill()
}

pane(NSRect(x: 138, y: 218, width: 344, height: 588), alpha: 0.96)
pane(NSRect(x: 546, y: 218, width: 344, height: 588), alpha: 0.62)

// File rows inside the panes.
func rows(x: CGFloat, tint: CGFloat, count: Int) {
    NSColor(calibratedRed: 0.16, green: 0.25, blue: 0.55, alpha: tint).setFill()
    for index in 0..<count {
        let y = 680 - CGFloat(index) * 96
        let width: CGFloat = index % 3 == 1 ? 230 : 274
        NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: width, height: 30),
            xRadius: 15,
            yRadius: 15
        ).fill()
    }
}
rows(x: 184, tint: 0.34, count: 5)
rows(x: 592, tint: 0.22, count: 5)

// Transfer arrow across both panes.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 330, y: 536))
arrow.line(to: NSPoint(x: 694, y: 536))
arrow.line(to: NSPoint(x: 694, y: 598))
arrow.line(to: NSPoint(x: 790, y: 512))
arrow.line(to: NSPoint(x: 694, y: 426))
arrow.line(to: NSPoint(x: 694, y: 488))
arrow.line(to: NSPoint(x: 330, y: 488))
arrow.close()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
let output = URL(fileURLWithPath: "Resources/icon-1024.png")
try png.write(to: output)
print("Wrote \(output.path)")
