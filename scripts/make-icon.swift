// Renders the Battery Anchor app icon (an anchor inside a battery) into an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>   (then: iconutil -c icns <output.iconset>)

import CoreGraphics
import Foundation
import ImageIO

let canvas: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let navyTop = rgb(0.13, 0.29, 0.49)
let navyBottom = rgb(0.04, 0.11, 0.22)
let greenTop = rgb(0.30, 0.85, 0.45)
let greenBottom = rgb(0.13, 0.62, 0.32)
let white = rgb(0.97, 0.97, 0.98)

func linearGradient(_ ctx: CGContext, _ top: CGColor, _ bottom: CGColor, from y0: CGFloat, to y1: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
}

/// Anchor strokes and flukes, in 1024-point top-left coordinates.
func anchorPath(flukeScale: CGFloat) -> (strokes: CGPath, flukes: CGPath) {
    let cx: CGFloat = 512
    let strokes = CGMutablePath()

    // Ring
    strokes.addEllipse(in: CGRect(x: cx - 40, y: 290, width: 80, height: 80))
    // Stock (crossbar)
    strokes.move(to: CGPoint(x: cx - 72, y: 412))
    strokes.addLine(to: CGPoint(x: cx + 72, y: 412))
    // Shank
    strokes.move(to: CGPoint(x: cx, y: 372))
    strokes.addLine(to: CGPoint(x: cx, y: 718))

    // Arms: lower arc
    let armCenter = CGPoint(x: cx, y: 608)
    let radius: CGFloat = 110
    let startAngle: CGFloat = 20 * .pi / 180
    let endAngle: CGFloat = 160 * .pi / 180
    let steps = 48
    for i in 0...steps {
        let a = startAngle + (endAngle - startAngle) * CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: armCenter.x + radius * cos(a), y: armCenter.y + radius * sin(a))
        if i == 0 { strokes.move(to: p) } else { strokes.addLine(to: p) }
    }

    // Flukes: arrowheads continuing each arm tip upward and outward
    let flukes = CGMutablePath()
    for (angle, direction) in [(endAngle, CGFloat(1)), (startAngle, CGFloat(-1))] {
        let tip = CGPoint(x: armCenter.x + radius * cos(angle), y: armCenter.y + radius * sin(angle))
        // Tangent pointing past the end of the arc.
        let dx = -sin(angle) * direction
        let dy = cos(angle) * direction
        let nx = -dy, ny = dx
        let base = CGPoint(x: tip.x - dx * 6, y: tip.y - dy * 6)
        let length = 58 * flukeScale, halfWidth = 30 * flukeScale
        flukes.move(to: CGPoint(x: tip.x + dx * length, y: tip.y + dy * length))
        flukes.addLine(to: CGPoint(x: base.x + nx * halfWidth, y: base.y + ny * halfWidth))
        flukes.addLine(to: CGPoint(x: base.x - nx * halfWidth, y: base.y - ny * halfWidth))
        flukes.closeSubpath()
    }
    return (strokes, flukes)
}

func render(size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / canvas
    // Small sizes get bolder strokes and no outline pass, which would otherwise blur into a smudge.
    let small = size <= 64
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // Top-left origin, 1024-point design space.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)

    // Background squircle (macOS icon grid: 824pt body, 185pt corner radius) with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(navyBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    linearGradient(ctx, navyTop, navyBottom, from: body.minY, to: body.maxY)
    ctx.restoreGState()

    // Battery body and terminal cap.
    let battery = CGRect(x: 327, y: 222, width: 370, height: 610)
    let inner = battery.insetBy(dx: 40, dy: 40)

    // Charge fill to 80%.
    let fillHeight = inner.height * 0.8
    let fill = CGRect(x: inner.minX, y: inner.maxY - fillHeight, width: inner.width, height: fillHeight)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.clip()
    linearGradient(ctx, greenTop, greenBottom, from: fill.minY, to: fill.maxY)
    ctx.restoreGState()

    ctx.setStrokeColor(white)
    ctx.setLineWidth(small ? 56 : 44)
    ctx.addPath(CGPath(roundedRect: battery, cornerWidth: 72, cornerHeight: 72, transform: nil))
    ctx.strokePath()

    ctx.setFillColor(white)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 437, y: 160, width: 150, height: 58), cornerWidth: 20, cornerHeight: 20, transform: nil))
    ctx.fillPath()

    // Anchor: a navy outline pass first so the white anchor separates from the green fill.
    let anchor = anchorPath(flukeScale: small ? 1.35 : 1)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let passes: [(CGColor, CGFloat)] = small ? [(white, 0)] : [(navyBottom, 16), (white, 0)]
    for (color, extra) in passes {
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth((small ? 46 : 30) + extra)
        ctx.addPath(anchor.strokes)
        ctx.strokePath()
        ctx.addPath(anchor.flukes)
        if extra > 0 {
            ctx.setLineWidth(extra)
            ctx.drawPath(using: .fillStroke)
        } else {
            ctx.fillPath()
        }
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    writePNG(render(size: points), to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(size: points * 2), to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("Wrote \(output.path)")
