// Renders the ClaudeMeter app icon (1024×1024 PNG).
// Run:  swift Tools/MakeIcon.swift  [outputPath]
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon-1024.png"

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
let S = CGFloat(size)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

// MARK: Rounded-square body (macOS squircle with margin + shadow)
let margin: CGFloat = 96
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.2237
let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 48, color: rgb(0, 0, 0, 0.30))
ctx.addPath(body); ctx.setFillColor(rgb(0, 0, 0)); ctx.fillPath()
ctx.restoreGState()

// Warm coral → rust diagonal gradient
ctx.saveGState()
ctx.addPath(body); ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [rgb(0.93, 0.56, 0.41), rgb(0.77, 0.34, 0.22)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// Top sheen
let sheen = CGGradient(colorsSpace: cs,
                       colors: [rgb(1, 1, 1, 0.20), rgb(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen,
                       start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.midY), options: [])
ctx.restoreGState()

// MARK: Gauge
let cx = rect.midX
let cy = rect.midY - rect.height * 0.015
let R = rect.width * 0.275
let lw = rect.width * 0.072
let d2r = CGFloat.pi / 180

// 270° sweep, open at the bottom: min at 225°, max at -45°, going over the top.
let startA = 225 * d2r
let value: CGFloat = 0.62                      // needle position (≈ "33%+" healthy meter)
let valueA = (225 - value * 270) * d2r

ctx.setLineCap(.round)

// Track
ctx.setStrokeColor(rgb(1, 1, 1, 0.26))
ctx.setLineWidth(lw)
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: startA,
           endAngle: -45 * d2r, clockwise: true)
ctx.strokePath()

// Value fill
ctx.setStrokeColor(rgb(1, 1, 1, 0.97))
ctx.setLineWidth(lw)
ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: startA,
           endAngle: valueA, clockwise: true)
ctx.strokePath()

// Tick dots at min / mid / max
for deg in [225.0, 90.0, -45.0] {
    let a = CGFloat(deg) * d2r
    let p = CGPoint(x: cx + (R) * cos(a), y: cy + (R) * sin(a))
    let dot = rect.width * 0.018
    ctx.setFillColor(rgb(1, 1, 1, 0.9))
    ctx.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
}

// Needle
let needleLen = R * 0.92
let tip = CGPoint(x: cx + needleLen * cos(valueA), y: cy + needleLen * sin(valueA))
let back = CGPoint(x: cx - R * 0.16 * cos(valueA), y: cy - R * 0.16 * sin(valueA))
ctx.setStrokeColor(rgb(1, 1, 1, 1))
ctx.setLineWidth(rect.width * 0.030)
ctx.setLineCap(.round)
ctx.move(to: back); ctx.addLine(to: tip); ctx.strokePath()

// Hub
let hubR = rect.width * 0.052
ctx.setFillColor(rgb(1, 1, 1, 1))
ctx.fillEllipse(in: CGRect(x: cx - hubR, y: cy - hubR, width: hubR * 2, height: hubR * 2))
ctx.setFillColor(rgb(0.80, 0.37, 0.25, 1))
let hubR2 = hubR * 0.45
ctx.fillEllipse(in: CGRect(x: cx - hubR2, y: cy - hubR2, width: hubR2 * 2, height: hubR2 * 2))

// MARK: Write PNG
guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(size)×\(size))")
