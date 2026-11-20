// Renders the app icon (1024px PNG) with CoreGraphics.
import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(srgbRed: 0.31, green: 0.49, blue: 1, alpha: 1).cgColor,
              NSColor(srgbRed: 0.55, green: 0.33, blue: 1, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
// clock ring
ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(56); ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: 512, y: 500), radius: 250, startAngle: .pi * 0.62, endAngle: .pi * 2.38, clockwise: false)
ctx.strokePath()
// check mark inside
ctx.setLineWidth(64); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 400, y: 505)); ctx.addLine(to: CGPoint(x: 485, y: 420)); ctx.addLine(to: CGPoint(x: 640, y: 590))
ctx.strokePath()
// top button
ctx.setFillColor(NSColor.white.cgColor)
ctx.fill(CGRect(x: 477, y: 772, width: 70, height: 60))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
