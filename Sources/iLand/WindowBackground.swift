import AppKit

/// Fundo da captura de janela: transparente (padrão, com a sombra do macOS), cor sólida ou o papel de parede.
enum WindowBackground {
    static func color(hex: String) -> NSColor? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    /// Reescreve o PNG com o fundo escolhido. Devolve false só se o arquivo não pôde ser lido ou gravado.
    static func apply(to url: URL) -> Bool {
        let mode = CapturePrefs.string(CapturePrefs.Key.windowBg)
        guard mode == "solid" || mode == "wallpaper" else { return true }
        guard let data = try? Data(contentsOf: url), let src = NSBitmapImageRep(data: data)?.cgImage,
              let ctx = CGContext(data: nil, width: src.width, height: src.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        let full = CGRect(x: 0, y: 0, width: src.width, height: src.height)
        var painted = false
        if mode == "wallpaper", let screen = NSScreen.main, let file = NSWorkspace.shared.desktopImageURL(for: screen),
           let wall = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let k = max(full.width / CGFloat(wall.width), full.height / CGFloat(wall.height))   // preenche, cortando o excesso
            let w = CGFloat(wall.width) * k, h = CGFloat(wall.height) * k
            ctx.draw(wall, in: CGRect(x: (full.width - w) / 2, y: (full.height - h) / 2, width: w, height: h)); painted = true
        }
        if !painted {
            ctx.setFillColor((color(hex: CapturePrefs.string(CapturePrefs.Key.windowColor)) ?? NSColor(white: 0.77, alpha: 1)).cgColor); ctx.fill(full)
        }
        ctx.draw(src, in: full)
        guard let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
