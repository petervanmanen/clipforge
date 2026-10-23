// Draws the FitMovie app icon and writes Resources/AppIcon.icns (macOS) and the iOS app-icon PNG.
// Usage: swift scripts/make_icon.swift   (run from the repository root)
import AppKit
import CoreGraphics

let size: CGFloat = 1024

/// `fullBleed`: iOS icons are square and opaque (the system rounds the corners), so the tile fills the canvas.
func drawIcon(fullBleed: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) in CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    // macOS icon grid: 824 pt rounded rect centred in 1024, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    if fullBleed {
        // Draw the same 824 pt design scaled up to fill the canvas.
        ctx.scaleBy(x: size / tile.width, y: size / tile.height)
        ctx.translateBy(x: -tile.minX, y: -tile.minY)
    }
    let tilePath = fullBleed ? CGPath(rect: tile, transform: nil)
        : CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0.04, 0.12, 0.25, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Ocean gradient background.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        rgb(0.02, 0.10, 0.28, 1), rgb(0.03, 0.33, 0.55, 1), rgb(0.10, 0.70, 0.78, 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Film-strip sprocket rows along the top and bottom.
    ctx.setFillColor(rgb(1, 1, 1, 0.16))
    for y in [150.0, 834.0] {
        ctx.fill(CGRect(x: 100, y: y - 26, width: 824, height: 92))
    }
    ctx.setFillColor(rgb(1, 1, 1, 0.55))
    for i in 0..<8 {
        let x = 152 + CGFloat(i) * 96
        for y in [150.0, 834.0] {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 48, height: 40), cornerWidth: 9, cornerHeight: 9, transform: nil))
        }
    }
    ctx.fillPath()

    // Play triangle.
    let play = CGMutablePath()
    play.move(to: CGPoint(x: 398, y: 680))
    play.addLine(to: CGPoint(x: 398, y: 344))
    play.addLine(to: CGPoint(x: 690, y: 512))
    play.closeSubpath()
    ctx.addPath(play)
    ctx.setFillColor(rgb(0.97, 0.98, 1, 1))
    ctx.setLineJoin(.round)
    ctx.setLineWidth(56)
    ctx.setStrokeColor(rgb(0.97, 0.98, 1, 1))
    ctx.drawPath(using: .fillStroke)

    // Heart-rate trace running through the frame.
    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 100, y: 470))
    pulse.addLine(to: CGPoint(x: 300, y: 470))
    pulse.addLine(to: CGPoint(x: 345, y: 400))
    pulse.addLine(to: CGPoint(x: 405, y: 610))
    pulse.addLine(to: CGPoint(x: 470, y: 300))
    pulse.addLine(to: CGPoint(x: 530, y: 520))
    pulse.addLine(to: CGPoint(x: 570, y: 470))
    pulse.addLine(to: CGPoint(x: 924, y: 470))
    ctx.addPath(pulse)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(46)
    ctx.setStrokeColor(rgb(0.04, 0.14, 0.30, 0.9))
    ctx.strokePath()
    ctx.addPath(pulse)
    ctx.setLineWidth(26)
    ctx.setStrokeColor(rgb(1, 0.30, 0.36, 1))
    ctx.strokePath()

    // Subtle top highlight.
    let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        rgb(1, 1, 1, 0.18), rgb(1, 1, 1, 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, pixels: Int, to url: URL, opaque: Bool = false) {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: alpha.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try! fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)

let icon = drawIcon()
for base in [16, 32, 128, 256, 512] {
    writePNG(icon, pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(icon, pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(icon, pixels: 1024, to: root.appendingPathComponent("Resources/AppIcon.png"))

let iosIconSet = root.appendingPathComponent("iOS/FitMovie/Assets.xcassets/AppIcon.appiconset")
try! fm.createDirectory(at: iosIconSet, withIntermediateDirectories: true)
writePNG(drawIcon(fullBleed: true), pixels: 1024, to: iosIconSet.appendingPathComponent("AppIcon.png"), opaque: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
