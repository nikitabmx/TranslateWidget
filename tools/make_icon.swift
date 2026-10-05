import Cocoa

// Generates a 1024×1024 app-icon PNG in the macOS "Icon Composer" glass style:
// a black globe mark on a fluted-glass or hologram pastel background.
// Usage: make_icon <output.png> [fluted|hologram]

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon.png"
let style = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "fluted"
let size: CGFloat = 1024

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!
ctx.imageInterpolation = .high

let full = NSRect(x: 0, y: 0, width: size, height: size)
let margin: CGFloat = 80
let iconRect = full.insetBy(dx: margin, dy: margin)
let radius = iconRect.width * 0.2237
let squircle = NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius)

NSGraphicsContext.saveGraphicsState()
squircle.addClip()

if style == "hologram" {
    // Iridescent foil: a saturated-enough pastel spectrum so the colours read.
    if let base = NSGradient(colorsAndLocations:
        (color(168, 224, 198), 0.0),    // mint
        (color(162, 210, 236), 0.22),   // cyan
        (color(190, 196, 240), 0.42),   // periwinkle
        (color(220, 190, 238), 0.60),   // lilac
        (color(247, 186, 212), 0.78),   // pink
        (color(250, 210, 174), 1.0)) {  // peach
        base.draw(in: iconRect, angle: 30)
    }
    // A second spectrum, soft-light blended, adds the oil-slick shimmer without
    // washing the colours out.
    NSGraphicsContext.current?.compositingOperation = .softLight
    if let interference = NSGradient(colorsAndLocations:
        (color(255, 180, 214), 0.0),   // pink
        (color(160, 226, 232), 0.34),  // aqua
        (color(206, 190, 246), 0.66),  // lilac
        (color(214, 244, 188), 1.0)) { // green
        interference.draw(in: iconRect, angle: -52)
    }
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    // Subtle top-left gloss (kept low so it doesn't white-out the foil).
    if let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28),
                                       NSColor.white.withAlphaComponent(0.0)]) {
        sheen.draw(in: iconRect, relativeCenterPosition: NSPoint(x: -0.45, y: 0.55))
    }
} else {
    // Fluted glass: pale horizontal iridescent gradient...
    if let base = NSGradient(colorsAndLocations:
        (color(246, 220, 230), 0.0),   // pale pink
        (color(252, 234, 216), 0.26),  // pale peach
        (color(255, 255, 255), 0.5),   // white
        (color(230, 225, 251), 0.74),  // pale lavender
        (color(220, 239, 234), 1.0)) { // pale mint
        base.draw(in: iconRect, angle: 0)
    }
    // ...overlaid with vertical glass ribs.
    let period: CGFloat = 21
    var x = iconRect.minX
    while x < iconRect.maxX {
        let band = NSRect(x: x, y: iconRect.minY, width: period, height: iconRect.height)
        if let rib = NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0.0), 0.0),
            (NSColor.white.withAlphaComponent(0.5), 0.30),
            (NSColor.black.withAlphaComponent(0.10), 0.72),
            (NSColor.white.withAlphaComponent(0.0), 1.0)) {
            rib.draw(in: band, angle: 0)
        }
        x += period
    }
    // Top highlight.
    if let top = NSGradient(colors: [NSColor.white.withAlphaComponent(0.35),
                                     NSColor.white.withAlphaComponent(0.0)]) {
        top.draw(in: iconRect, angle: -90)
    }
}

NSGraphicsContext.restoreGraphicsState()

// Glassy rim.
let rim = NSBezierPath(roundedRect: iconRect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
NSColor.white.withAlphaComponent(0.55).setStroke()
rim.lineWidth = 2
rim.stroke()
NSColor.black.withAlphaComponent(0.06).setStroke()
squircle.lineWidth = 1
squircle.stroke()

// Black globe mark, centered, with a soft lift shadow.
let glyphSize = size * 0.62
let glyphRect = NSRect(x: (size - glyphSize) / 2, y: (size - glyphSize) / 2,
                       width: glyphSize, height: glyphSize)
let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .regular)
if let base = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let mark = NSImage(size: base.size)
    mark.lockFocus()
    color(26, 26, 28).set()
    let r = NSRect(origin: .zero, size: base.size)
    base.draw(in: r)
    r.fill(using: .sourceAtop)
    mark.unlockFocus()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    mark.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to render icon\n".data(using: .utf8)!)
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) [\(style)]")
