import AppKit
// Draws Glint's icon: a light-blue rounded square holding a dark screen with a small cursor dot.
let out = CommandLine.arguments[1]
func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let r = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)); ctx.clip()
    // Flat light blue, slightly deeper toward the bottom so it reads as a surface, not a sticker.
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor(srgbRed: 0.50, green: 0.78, blue: 1.0, alpha: 1).cgColor, NSColor(srgbRed: 0.33, green: 0.65, blue: 0.98, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    // Screen.
    let screen = CGRect(x: s * 0.23, y: s * 0.30, width: s * 0.54, height: s * 0.38)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: s * 0.045, cornerHeight: s * 0.045, transform: nil))
    ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // A line of "content" and a cursor dot: what Glint looks at.
    ctx.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
    ctx.fill(CGRect(x: s * 0.29, y: s * 0.56, width: s * 0.26, height: s * 0.035))
    ctx.fill(CGRect(x: s * 0.29, y: s * 0.48, width: s * 0.18, height: s * 0.035))
    ctx.setFillColor(NSColor(srgbRed: 0.50, green: 0.78, blue: 1.0, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: s * 0.60, y: s * 0.36, width: s * 0.10, height: s * 0.10))
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
let fm = FileManager.default
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
for (n, sz) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(sz).write(to: URL(fileURLWithPath: "\(out)/icon_\(n).png"))
}
