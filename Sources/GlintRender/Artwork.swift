import Foundation
import CoreGraphics
import CoreImage
import CoreText
import AppKit
import GlintCore

/// Built-in backgrounds. Palettes are Glint's own.
public enum BackgroundPresets {
    public struct Preset: Sendable { public let name: String; public let colors: [RGBA]; public let glow: RGBA }
    public static let all: [Preset] = [
        Preset(name: "dusk", colors: [RGBA(hex: "#2B1B54")!, RGBA(hex: "#7A3E9D")!, RGBA(hex: "#F28C7A")!], glow: RGBA(1, 0.85, 0.75, 0.22)),
        Preset(name: "ocean", colors: [RGBA(hex: "#0B2447")!, RGBA(hex: "#19376D")!, RGBA(hex: "#3FA7D6")!], glow: RGBA(0.7, 0.9, 1, 0.2)),
        Preset(name: "mint", colors: [RGBA(hex: "#0F3D3E")!, RGBA(hex: "#1F7A6B")!, RGBA(hex: "#9BE3C3")!], glow: RGBA(0.85, 1, 0.9, 0.2)),
        Preset(name: "graphite", colors: [RGBA(hex: "#16181D")!, RGBA(hex: "#2A2E37")!, RGBA(hex: "#4A505E")!], glow: RGBA(1, 1, 1, 0.08)),
        Preset(name: "sunset", colors: [RGBA(hex: "#FF7A59")!, RGBA(hex: "#FF4E8A")!, RGBA(hex: "#7B5CFF")!], glow: RGBA(1, 0.9, 0.8, 0.22)),
        Preset(name: "aurora", colors: [RGBA(hex: "#061A2B")!, RGBA(hex: "#14625A")!, RGBA(hex: "#7B61FF")!], glow: RGBA(0.7, 1, 0.9, 0.18)),
        Preset(name: "paper", colors: [RGBA(hex: "#F4F1EA")!, RGBA(hex: "#E7E1D6")!, RGBA(hex: "#D9D1C4")!], glow: RGBA(1, 1, 1, 0.5)),
        Preset(name: "midnight", colors: [RGBA(hex: "#05060A")!, RGBA(hex: "#101528")!, RGBA(hex: "#22305A")!], glow: RGBA(0.6, 0.7, 1, 0.12)),
    ]
    public static var names: [String] { all.map(\.name) }
    public static func preset(_ name: String) -> Preset { all.first { $0.name == name } ?? all[0] }
}

enum Artwork {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func cg(_ c: RGBA) -> CGColor { CGColor(colorSpace: sRGB, components: [c.r, c.g, c.b, c.a])! }

    static func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()
    }

    /// Background at canvas size (CI coordinates, origin 0,0).
    static func background(_ style: BackgroundStyle, width: Int, height: Int, bundle: ProjectBundle?) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        switch style.kind {
        case .none:
            return CIImage(color: .black).cropped(to: rect)
        case .solid:
            let c = style.colors.first ?? RGBA(0.1, 0.1, 0.12)
            return CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)).cropped(to: rect)
        case .image:
            if let p = style.imagePath {
                let url = bundle?.resolve(p) ?? URL(fileURLWithPath: p)
                if let img = CIImage(contentsOf: url) {
                    // Aspect-fill.
                    let s = max(Double(width) / img.extent.width, Double(height) / img.extent.height)
                    var out = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                    out = out.transformed(by: CGAffineTransform(translationX: (Double(width) - out.extent.width) / 2 - out.extent.minX,
                                                                y: (Double(height) - out.extent.height) / 2 - out.extent.minY))
                    if style.blur > 0 { out = out.clampedToExtent().applyingGaussianBlur(sigma: style.blur) }
                    return out.cropped(to: rect)
                }
            }
            fallthrough
        case .gradient:
            let preset = BackgroundPresets.preset(style.preset)
            let colors = style.colors.count >= 2 ? style.colors : preset.colors
            let glow = preset.glow
            let img = bitmap(width, height) { ctx in
                let cgColors = colors.map(cg) as CFArray
                let locs = (0..<colors.count).map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
                guard let g = CGGradient(colorsSpace: sRGB, colors: cgColors, locations: locs) else { return }
                let a = style.angle * .pi / 180
                let cx = Double(width) / 2, cy = Double(height) / 2
                let r = (Double(width * width + height * height)).squareRoot() / 2
                // CG y-up; angle 0 = left→right, 90 = bottom→top.
                ctx.drawLinearGradient(g, start: CGPoint(x: cx - cos(a) * r, y: cy - sin(a) * r), end: CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                // Soft top-left glow for depth.
                if let rg = CGGradient(colorsSpace: sRGB, colors: [cg(glow), cg(RGBA(glow.r, glow.g, glow.b, 0))] as CFArray, locations: [0, 1]) {
                    ctx.drawRadialGradient(rg, startCenter: CGPoint(x: Double(width) * 0.22, y: Double(height) * 0.85), startRadius: 0,
                                           endCenter: CGPoint(x: Double(width) * 0.22, y: Double(height) * 0.85), endRadius: Double(max(width, height)) * 0.7, options: [])
                }
            }
            guard let img else { return CIImage(color: .black).cropped(to: rect) }
            // Fine dither noise prevents banding after video compression.
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: rect)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.012, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.012, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.012, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: -0.006, y: -0.006, z: -0.006, w: 0)])
            return noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(cgImage: img)]).cropped(to: rect)
        }
    }

    /// A crisp vector arrow cursor (Glint's own drawing), rendered large; hotspot at the tip.
    static func arrowCursor(pixelHeight: Int = 192) -> (CIImage, hot: CGPoint, sizePt: CGSize)? {
        let h = Double(pixelHeight), w = h * 0.72
        let s = h / 28.0   // design grid: 20 × 28 pt
        let img = bitmap(Int(w), Int(h)) { ctx in
            ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)   // y-down drawing
            let p = CGMutablePath()
            let pts: [(Double, Double)] = [(2.5, 2), (2.5, 22.5), (7.6, 17.6), (11.2, 25.8), (14.6, 24.3), (11.1, 16.3), (18.3, 16.1)]
            p.move(to: CGPoint(x: pts[0].0 * s, y: pts[0].1 * s))
            for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0 * s, y: q.1 * s)) }
            p.closeSubpath()
            ctx.setShadow(offset: CGSize(width: 0, height: 1.2 * s), blur: 2.4 * s, color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(p); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(3.2 * s); ctx.setLineJoin(.round)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.drawPath(using: .fillStroke)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(p); ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillPath()
        }
        guard let img else { return nil }
        // Hotspot in points, top-left origin (matches NSCursor conventions).
        return (CIImage(cgImage: img), CGPoint(x: 2.5, y: 2), CGSize(width: 20, height: 28))
    }

    /// Soft ring used for click ripples (white, transparent center).
    static func ring(size: Int = 256) -> CIImage? {
        let img = bitmap(size, size) { ctx in
            let c = CGPoint(x: size / 2, y: size / 2)
            let r = Double(size) / 2 - 6
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(Double(size) * 0.05)
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.strokePath()
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        return img.map { CIImage(cgImage: $0) }
    }

    /// Caption image: one line of text, optionally with the active word highlighted, on a rounded pill.
    static func caption(text: String, words: [String], activeWord: Int?, style: CaptionStyle, canvasHeight: Double, maxWidth: Double) -> CIImage? {
        let fontSize = max(12, style.size * canvasHeight)
        let font = CTFontCreateWithName("SF Pro Display Semibold" as CFString, fontSize, nil)
        let fallback = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let useFont: CTFont = CTFontCopyFamilyName(font) as String == "SF Pro Display" ? font : fallback as CTFont
        let attr = NSMutableAttributedString()
        let tokens = words.isEmpty ? text.split(separator: " ").map(String.init) : words
        for (i, w) in tokens.enumerated() {
            let isActive = style.look == .highlight && i == activeWord
            let color = isActive ? style.highlightColor : style.textColor
            attr.append(NSAttributedString(string: (i > 0 ? " " : "") + w, attributes: [
                .font: useFont, .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a),
            ]))
        }
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        var width = Double(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padX = fontSize * 0.7, padY = fontSize * 0.42
        var scale = 1.0
        if width + 2 * padX > maxWidth { scale = maxWidth / (width + 2 * padX) }
        width *= scale
        let w = Int((width + 2 * padX * scale).rounded(.up)), h = Int(((ascent + descent) * scale + 2 * padY * scale).rounded(.up))
        let img = bitmap(w, h) { ctx in
            if style.look != .plain {
                let bg = style.backgroundColor
                let rr = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: Double(h) * 0.32, cornerHeight: Double(h) * 0.32, transform: nil)
                ctx.addPath(rr); ctx.setFillColor(cg(bg)); ctx.fillPath()
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: fontSize * 0.25, color: CGColor(gray: 0, alpha: 0.85))
            }
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = CGPoint(x: padX, y: padY + descent)
            CTLineDraw(line, ctx)
        }
        return img.map { CIImage(cgImage: $0) }
    }
}
