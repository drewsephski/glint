import AppKit
// Draws Glint's icon: a rounded square with a violet→coral gradient, a framed "screen" and a spark.
let out = CommandLine.arguments[1]
func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let r = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = CGPath(roundedRect: r, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor(srgbRed: 0.36, green: 0.25, blue: 0.95, alpha: 1).cgColor, NSColor(srgbRed: 1, green: 0.47, blue: 0.4, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
    let screen = CGRect(x: s * 0.24, y: s * 0.32, width: s * 0.52, height: s * 0.36)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil))
    ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Spark (four-point star) bottom-right of the screen.
    let c = CGPoint(x: s * 0.66, y: s * 0.38), R = s * 0.13, rr = s * 0.035
    let star = CGMutablePath()
    for i in 0..<8 { let a = CGFloat(i) * .pi / 4 + .pi / 2; let rad = i % 2 == 0 ? R : rr
        let p = CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad); if i == 0 { star.move(to: p) } else { star.addLine(to: p) } }
    star.closeSubpath(); ctx.addPath(star); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
let fm = FileManager.default
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
for (n, sz) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(sz).write(to: URL(fileURLWithPath: "\(out)/icon_\(n).png"))
}
