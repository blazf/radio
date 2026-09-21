// Renders the app icon: swift Tools/make-icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

// Apple's macOS icon grid: 824pt squircle centered in 1024 with ~185pt corners.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSShadow().set()

let top = NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.30, alpha: 1)
let bottom = NSColor(calibratedRed: 0.62, green: 0.13, blue: 0.48, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -70)

// Soft highlight in the upper part.
let hi = NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
ctx.saveGraphicsState()
shape.addClip()
hi.draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: 90)
ctx.restoreGraphicsState()

// Radio symbol, tinted white.
let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)
let symbol = NSImage(systemSymbolName: "radio.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let tinted = NSImage(size: symbol.size, flipped: false) { r in
    symbol.draw(in: r)
    NSColor.white.set()
    r.fill(using: .sourceAtop)
    return true
}
let symShadow = NSShadow()
symShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
symShadow.shadowBlurRadius = 12
symShadow.shadowOffset = NSSize(width: 0, height: -6)
symShadow.set()
let s = tinted.size
tinted.draw(in: NSRect(x: (1024 - s.width) / 2, y: (1024 - s.height) / 2 + 10, width: s.width, height: s.height))

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
