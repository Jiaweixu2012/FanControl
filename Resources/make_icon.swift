import AppKit

func drawFan(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // background
    NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()

    let c = NSGraphicsContext.current!.cgContext
    c.saveGState()
    c.translateBy(x: size / 2, y: size / 2)

    // hub
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: -size * 0.05, y: -size * 0.05, width: size * 0.10, height: size * 0.10)).fill()

    // 4 curved blades
    let blade = NSBezierPath()
    blade.move(to: NSPoint(x: size * 0.02, y: size * 0.10))
    blade.curve(to: NSPoint(x: size * 0.28, y: size * 0.42),
                controlPoint1: NSPoint(x: size * 0.02, y: size * 0.26),
                controlPoint2: NSPoint(x: size * 0.12, y: size * 0.40))
    blade.curve(to: NSPoint(x: size * 0.38, y: size * 0.10),
                controlPoint1: NSPoint(x: size * 0.38, y: size * 0.32),
                controlPoint2: NSPoint(x: size * 0.40, y: size * 0.20))
    blade.close()
    NSColor.white.setFill()
    for i in 0..<4 {
        c.saveGState()
        c.rotate(by: .pi / 2 * CGFloat(i))
        blade.fill()
        c.restoreGState()
    }
    c.restoreGState()
    return image
}

func writePNG(_ image: NSImage, to url: URL, size: CGFloat) {
    guard let rep = NSBitmapImageRep(data: image.tiffRepresentation!) else { return }
    let scaled = NSImage(size: NSSize(width: size, height: size))
    scaled.lockFocus()
    rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    scaled.unlockFocus()
    guard let tiff = scaled.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let base = drawFan(size: 1024)
let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    writePNG(base, to: iconset.appendingPathComponent(name), size: px)
}
print(iconset.path)
