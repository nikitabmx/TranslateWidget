// Renders the DMG window background at 1x and 2x: a caption, a first-launch
// hint and a soft arrow from the app icon to the Applications folder.
// Geometry must match the icon positions in build_dmg.sh.
//
// Usage: swift make_dmg_background.swift out.png out@2x.png
import AppKit

// Taller than the window's content on purpose: Finder may add a tab bar/path bar
// (global user settings) or leave spare room below — either way it stays white.
let size = NSSize(width: 600, height: 560)   // points
let iconRowY: CGFloat = 165                  // icon centers, measured from the top
let appX: CGFloat = 160
let applicationsX: CGFloat = 440
let iconSize: CGFloat = 100

func render(scale: CGFloat, to path: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("can't allocate bitmap")
    }
    rep.size = size // draw in points; the context scales to pixels
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()

    func centered(_ text: String, font: NSFont, color: NSColor, top: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (size.width - textSize.width) / 2, y: size.height - top - textSize.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
    centered("Перетащи TranslateWidget в «Программы»",
             font: .systemFont(ofSize: 18, weight: .semibold), color: NSColor(white: 0.12, alpha: 1), top: 36)
    centered("Первый запуск: правый клик по приложению → «Открыть»",
             font: .systemFont(ofSize: 12.5), color: NSColor(white: 0.52, alpha: 1), top: 60)

    // Arrow from the app icon to the Applications folder.
    let y = size.height - iconRowY
    let start = appX + iconSize / 2 + 22
    let end = applicationsX - iconSize / 2 - 22
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: start, y: y))
    arrow.line(to: NSPoint(x: end, y: y))
    arrow.move(to: NSPoint(x: end - 12, y: y + 11))
    arrow.line(to: NSPoint(x: end, y: y))
    arrow.line(to: NSPoint(x: end - 12, y: y - 11))
    arrow.lineWidth = 3.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(white: 0.75, alpha: 1).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("can't encode PNG") }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        fatalError("can't write \(path): \(error)")
    }
}

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: make_dmg_background.swift out.png out@2x.png")
    exit(1)
}
render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
