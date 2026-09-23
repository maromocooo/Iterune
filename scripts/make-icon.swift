import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = AffineTransform(scale: factor)
        (transform as NSAffineTransform).concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.43, green: 0.36, blue: 0.78, alpha: 1), ending: NSColor(calibratedRed: 0.19, green: 0.18, blue: 0.35, alpha: 1))!.draw(in: background, angle: -70)
        for (offset, opacity) in [(CGFloat(-130), CGFloat(0.25)), (CGFloat(-20), CGFloat(0.55)), (CGFloat(90), CGFloat(1))] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 280, y: 440 + offset))
            path.line(to: NSPoint(x: 512, y: 570 + offset))
            path.line(to: NSPoint(x: 744, y: 440 + offset))
            path.line(to: NSPoint(x: 512, y: 310 + offset))
            path.close()
            NSColor.white.withAlphaComponent(opacity).setFill(); path.fill()
        }
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
