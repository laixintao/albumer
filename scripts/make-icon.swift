import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = root.appendingPathComponent("Sources/Albumer/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func makeImage(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
    let outline = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
    let shadow = NSShadow(); shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.shadowBlurRadius = 30
    shadow.shadowColor = .black.withAlphaComponent(0.4); shadow.set()
    NSColor(calibratedWhite: 0.09, alpha: 1).setFill(); outline.fill()
    NSShadow().set()
    NSGradient(starting: NSColor(red: 0.21, green: 0.23, blue: 0.22, alpha: 1), ending: NSColor(red: 0.055, green: 0.065, blue: 0.06, alpha: 1))!.draw(in: outline, angle: -65)
    NSColor.white.withAlphaComponent(0.13).setStroke(); outline.lineWidth = 2; outline.stroke()
    for index in (0..<3).reversed() {
        NSGraphicsContext.saveGraphicsState()
        let rotation = NSAffineTransform()
        rotation.translateX(by: 512, yBy: 500); rotation.rotate(byDegrees: CGFloat(index) * 9)
        rotation.translateX(by: -512, yBy: -500); rotation.concat()
        let rect = NSRect(x: 300 - index * 18, y: 270 + index * 20, width: 442, height: 490)
        let sleeve = NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24)
        NSColor(red: 0.13, green: 0.15, blue: 0.14, alpha: 1).setFill(); sleeve.fill()
        NSColor(red: 0.87, green: 0.80, blue: 0.65, alpha: index == 0 ? 1 : 0.4).setStroke()
        sleeve.lineWidth = index == 0 ? 6 : 3; sleeve.stroke()
        if index == 0 {
            for radius: CGFloat in [134, 128, 121, 44] {
                let circle = NSBezierPath(ovalIn: NSRect(x: 521 - radius, y: 515 - radius, width: radius * 2, height: radius * 2))
                NSColor(red: 0.87, green: 0.80, blue: 0.65, alpha: radius == 134 || radius == 44 ? 0.9 : 0.18).setStroke()
                circle.lineWidth = radius == 44 ? 3 : 2; circle.stroke()
            }
            NSColor(red: 0.87, green: 0.80, blue: 0.65, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 513, y: 507, width: 16, height: 16)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try makeImage(size * scale).write(to: destination.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
