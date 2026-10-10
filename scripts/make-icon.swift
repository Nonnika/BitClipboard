import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let base = NSBezierPath(roundedRect: NSRect(x: p * 0.055, y: p * 0.055, width: p * 0.89, height: p * 0.89), xRadius: p * 0.22, yRadius: p * 0.22)
        NSColor.black.setFill()
        base.fill()
        NSColor.white.setStroke()
        let clipboard = NSBezierPath(roundedRect: NSRect(x: p * 0.30, y: p * 0.235, width: p * 0.40, height: p * 0.51), xRadius: p * 0.055, yRadius: p * 0.055)
        clipboard.lineWidth = p * 0.034
        clipboard.stroke()
        // A solid clip keeps the silhouette clear at small Finder icon sizes.
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: p * 0.385, y: p * 0.705, width: p * 0.23, height: p * 0.08)).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.405, y: p * 0.705, width: p * 0.19, height: p * 0.09), xRadius: p * 0.032, yRadius: p * 0.032).fill()
        for y in [0.56, 0.445, 0.33] {
            NSBezierPath(roundedRect: NSRect(x: p * 0.385, y: p * y, width: p * (y == 0.33 ? 0.145 : 0.23), height: p * 0.028), xRadius: p * 0.014, yRadius: p * 0.014).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
