// make-icon.swift
// Draws the Laptop Alarm app icon and writes an .iconset folder of PNGs.
//
// Usage: make-icon OUT_DIR
// - ./build.sh app compiles and runs this, then packs the folder with iconutil.
// - Art is drawn on a 1024 grid and scaled to each size, so every size is sharp.
// - Sizes of 64 px and below drop the siren rays so the icon stays readable.

import AppKit

func hex(_ v: UInt32) -> CGColor {
    CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(path)
    ctx.fillPath()
}

func drawIcon(_ ctx: CGContext, pixels: Int) {
    let detailed = pixels > 64

    // Work in a 1024 grid with the origin at the top left, like the design sketch.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)

    // macOS icon body is 824 of 1024, centered.
    let k: CGFloat = 824.0 / 944.0
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -512, y: -512)

    // Background: dark rounded square with a vertical gradient.
    ctx.saveGState()
    ctx.addPath(roundedRect(40, 40, 944, 944, 210))
    ctx.clip()
    let colors = [hex(0x3A3F4B), hex(0x14161C)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 40), end: CGPoint(x: 0, y: 984), options: [])
    ctx.restoreGState()

    // Siren light above the laptop.
    let dome = CGMutablePath()
    dome.move(to: CGPoint(x: 452, y: 300))
    dome.addCurve(to: CGPoint(x: 512, y: 240), control1: CGPoint(x: 452, y: 266.9), control2: CGPoint(x: 478.9, y: 240))
    dome.addCurve(to: CGPoint(x: 572, y: 300), control1: CGPoint(x: 545.1, y: 240), control2: CGPoint(x: 572, y: 266.9))
    dome.closeSubpath()
    fill(ctx, dome, hex(0xFF4D3D))
    fill(ctx, roundedRect(444, 296, 136, 22, 8), hex(0xC9CDD6))

    if detailed {
        ctx.setStrokeColor(hex(0xFF7A4D))
        ctx.setLineWidth(22)
        ctx.setLineCap(.round)
        for (a, b) in [((392.0, 214.0), (350.0, 176.0)), ((512.0, 180.0), (512.0, 122.0)), ((632.0, 214.0), (674.0, 176.0))] {
            ctx.move(to: CGPoint(x: a.0, y: a.1))
            ctx.addLine(to: CGPoint(x: b.0, y: b.1))
            ctx.strokePath()
        }
    }

    // Laptop: screen, display, base.
    fill(ctx, roundedRect(262, 350, 500, 320, 30), hex(0xEEF1F6))
    fill(ctx, roundedRect(292, 380, 440, 260, 14), hex(0x1B2230))
    let base = CGMutablePath()
    base.move(to: CGPoint(x: 212, y: 700))
    base.addLine(to: CGPoint(x: 812, y: 700))
    base.addLine(to: CGPoint(x: 790, y: 748))
    base.addQuadCurve(to: CGPoint(x: 768, y: 762), control: CGPoint(x: 784, y: 762))
    base.addLine(to: CGPoint(x: 256, y: 762))
    base.addQuadCurve(to: CGPoint(x: 234, y: 748), control: CGPoint(x: 240, y: 762))
    base.closeSubpath()
    fill(ctx, base, hex(0xC9CDD6))

    // Shield on the screen.
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 430))
    shield.addLine(to: CGPoint(x: 592, y: 470))
    shield.addLine(to: CGPoint(x: 592, y: 530))
    shield.addCurve(to: CGPoint(x: 512, y: 622), control1: CGPoint(x: 592, y: 580), control2: CGPoint(x: 556, y: 606))
    shield.addCurve(to: CGPoint(x: 432, y: 530), control1: CGPoint(x: 468, y: 606), control2: CGPoint(x: 432, y: 580))
    shield.addLine(to: CGPoint(x: 432, y: 470))
    shield.closeSubpath()
    fill(ctx, shield, hex(0xFF4D3D))
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    drawIcon(gc.cgContext, pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon OUT_DIR\n".data(using: .utf8)!)
    exit(2)
}
let outDir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Names iconutil expects: base size and its 2x.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try png(pixels: pixels).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name + ".png"))
}
