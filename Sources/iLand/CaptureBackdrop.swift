import AppKit

/// Fundo da captura (como o "Backdrop" do Shottr): gradiente, margem, sombra e cantos arredondados em volta da imagem.
struct Backdrop: Equatable {
    struct Preset: Equatable { let name: String; let colors: [NSColor] }

    static let presets: [Preset] = [
        Preset(name: "Oceano", colors: [NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.45, green: 0.20, blue: 0.85, alpha: 1)]),
        Preset(name: "Pôr do sol", colors: [NSColor(srgbRed: 1.0, green: 0.55, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.90, green: 0.20, blue: 0.45, alpha: 1)]),
        Preset(name: "Floresta", colors: [NSColor(srgbRed: 0.10, green: 0.60, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.05, green: 0.25, blue: 0.35, alpha: 1)]),
        Preset(name: "Aurora", colors: [NSColor(srgbRed: 0.20, green: 0.85, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.35, green: 0.40, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.75, green: 0.30, blue: 0.90, alpha: 1)]),
        Preset(name: "Grafite", colors: [NSColor(white: 0.30, alpha: 1), NSColor(white: 0.08, alpha: 1)]),
        Preset(name: "Neve", colors: [NSColor(white: 0.98, alpha: 1), NSColor(srgbRed: 0.82, green: 0.86, blue: 0.93, alpha: 1)]),
    ]

    /// Proporções do fundo: nil = livre. Largura / altura.
    static let aspects: [(String, CGFloat?)] = [("Livre", nil), ("16:9", 16 / 9), ("4:3", 4 / 3), ("1:1", 1), ("3:4", 3 / 4), ("9:16", 9 / 16)]

    var enabled = false
    var padding: CGFloat = 0.08        // fração do lado maior da imagem
    var shadow: CGFloat = 0.5          // 0...1
    var innerRadius: CGFloat = 0.012   // fração do lado menor da imagem
    var outerRadius: CGFloat = 0
    var colors = presets[0].colors
    var radial = false
    var angle: CGFloat = 45            // graus, só no gradiente linear
    var aspect: CGFloat?

    mutating func reverse() { colors.reverse() }
    mutating func randomize() {
        func any() -> NSColor { NSColor(hue: .random(in: 0...1), saturation: .random(in: 0.5...0.9), brightness: .random(in: 0.6...1), alpha: 1) }
        colors = [any(), any()]; angle = CGFloat(Int.random(in: 0...7)) * 45
    }

    /// Tamanho final e onde a imagem fica dentro dele (origem embaixo à esquerda).
    func layout(for inner: CGSize) -> (size: CGSize, offset: CGPoint) {
        guard enabled else { return (inner, .zero) }
        let pad = (max(inner.width, inner.height) * padding).rounded()
        var size = CGSize(width: inner.width + 2 * pad, height: inner.height + 2 * pad)
        if let aspect {
            if size.width / size.height > aspect { size.height = (size.width / aspect).rounded() } else { size.width = (size.height * aspect).rounded() }
        }
        return (size, CGPoint(x: ((size.width - inner.width) / 2).rounded(), y: ((size.height - inner.height) / 2).rounded()))
    }

    /// Imagem final: fundo + sombra + imagem com cantos arredondados.
    func render(_ inner: CGImage) -> CGImage {
        let (size, offset) = layout(for: CGSize(width: inner.width, height: inner.height))
        guard enabled, let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return inner }
        let full = CGRect(origin: .zero, size: size)
        let minSide = CGFloat(min(inner.width, inner.height))
        let outer = min(outerRadius * max(size.width, size.height), min(size.width, size.height) / 2)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: full, cornerWidth: outer, cornerHeight: outer, transform: nil)); ctx.clip()
        let cg = colors.map(\.cgColor) as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cg, locations: nil) {
            if radial {
                ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0, endCenter: CGPoint(x: size.width / 2, y: size.height / 2), endRadius: hypot(size.width, size.height) / 2, options: [.drawsAfterEndLocation])
            } else {
                let r = angle * .pi / 180, d = hypot(size.width, size.height) / 2, c = CGPoint(x: size.width / 2, y: size.height / 2)
                ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - cos(r) * d, y: c.y - sin(r) * d), end: CGPoint(x: c.x + cos(r) * d, y: c.y + sin(r) * d), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        ctx.restoreGState()
        let rect = CGRect(origin: offset, size: CGSize(width: inner.width, height: inner.height))
        let radius = min(innerRadius * minSide, minSide / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -minSide * 0.02 * shadow), blur: minSide * 0.06 * shadow, color: NSColor.black.withAlphaComponent(0.55 * shadow).cgColor)
            ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState(); ctx.addPath(path); ctx.clip(); ctx.draw(inner, in: rect); ctx.restoreGState()
        return ctx.makeImage() ?? inner
    }
}
