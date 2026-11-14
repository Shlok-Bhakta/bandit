// Usage: swiftc -O tools/make-dongle-icon.swift -o /tmp/make-dongle-icon && /tmp/make-dongle-icon NPDongle/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// Draws NP Dongle's app icon: a USB dongle sending radio waves, on a dark gradient.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

// Background: deep navy to near black, top to bottom.
let background = CGGradient(colorsSpace: space, colors: [color(0.09, 0.11, 0.22), color(0.02, 0.02, 0.06)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])
// A soft glow behind the dongle.
let glow = CGGradient(colorsSpace: space, colors: [color(0.2, 0.85, 0.65, 0.35), color(0.2, 0.85, 0.65, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 430), startRadius: 0, endCenter: CGPoint(x: 512, y: 430), endRadius: 430, options: [])

// The dongle body, tilted slightly, pointing up.
ctx.saveGState()
ctx.translateBy(x: 512, y: 400)
ctx.rotate(by: -0.0)
let body = CGRect(x: -150, y: -250, width: 300, height: 400)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 70, cornerHeight: 70, transform: nil)
ctx.addPath(bodyPath)
ctx.clip()
let bodyGradient = CGGradient(colorsSpace: space, colors: [color(0.38, 0.58, 1.0), color(0.2, 0.85, 0.65)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bodyGradient, start: CGPoint(x: -150, y: -250), end: CGPoint(x: 150, y: 150), options: [])
ctx.resetClip()
// The connector.
let plug = CGRect(x: -95, y: 150, width: 190, height: 130)
ctx.setFillColor(color(0.82, 0.86, 0.94))
ctx.addPath(CGPath(roundedRect: plug, cornerWidth: 18, cornerHeight: 18, transform: nil))
ctx.fillPath()
ctx.setFillColor(color(0.09, 0.11, 0.22))
for x in [-55.0, 15.0] { ctx.fill(CGRect(x: x, y: 205, width: 40, height: 34)) }
// A status light.
ctx.setFillColor(color(1, 1, 1, 0.95))
ctx.fillEllipse(in: CGRect(x: -26, y: -140, width: 52, height: 52))
ctx.restoreGState()

// Radio waves above the connector.
ctx.setLineCap(.round)
for (i, radius) in [120.0, 200.0, 280.0].enumerated() {
    ctx.setStrokeColor(color(0.2, 0.85, 0.65, 1 - Double(i) * 0.25))
    ctx.setLineWidth(46)
    ctx.addArc(center: CGPoint(x: 512, y: 640), radius: radius, startAngle: .pi * 0.28, endAngle: .pi * 0.72, clockwise: false)
    ctx.strokePath()
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
