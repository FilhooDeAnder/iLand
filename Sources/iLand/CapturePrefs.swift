import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Preferências da captura (UserDefaults). As views usam @AppStorage com as mesmas chaves.
enum CapturePrefs {
    enum Key {
        static let afterArea = "capAfterArea"        // thumbnail | editor
        static let show = "capShow"                  // mostrar depois da captura
        static let copy = "capCopy"                  // copiar sozinho
        static let save = "capSave"                  // salvar sozinho na pasta
        static let thumbClose = "capThumbClose"      // manual | outside
        static let folder = "capFolder"
        static let format = "capFormat"              // auto | png | jpeg
        static let downscale = "capDownscale"        // salvar em 1× (Retina)
        static let windowBg = "capWindowBg"          // transparent | solid | wallpaper (fundo da captura de janela)
        static let windowColor = "capWindowColor"    // "#RRGGBB" quando solid
        static let trimShadow = "capTrimShadow"      // captura de janela sem a sombra
        static let ocrLanguage = "capOCRLanguage"
        static let ocrBreaks = "capOCRBreaks"        // tirar quebras de linha
        static let confirm = "capConfirm"            // custom | system | none
        static let esc = "capEsc"                    // none | copy | save (ao fechar o editor com Esc)
        static let zoom100 = "capZoom100"
        static let reverseZoom = "capReverseZoom"
        static let scrollMax = "capScrollMax"        // altura máxima da captura com rolagem, em pixels
        static let scrollSpeed = "capScrollSpeed"    // 1…10
        static let scrollReverse = "capScrollReverse"
        static let deeplinks = "capDeeplinks"
        static let lastRect = "capLastRect"          // última área capturada "x,y,w,h" (origem no canto superior esquerdo)
    }

    static let defaults: [String: Any] = [
        Key.afterArea: "thumbnail", Key.show: true, Key.copy: false, Key.save: false, Key.thumbClose: "manual",
        Key.folder: "", Key.format: "auto", Key.downscale: false, Key.trimShadow: false, Key.windowBg: "transparent", Key.windowColor: "#C4C6C8",
        Key.ocrLanguage: "pt-BR", Key.ocrBreaks: false, Key.confirm: "custom", Key.esc: "none",
        Key.zoom100: false, Key.reverseZoom: false, Key.scrollMax: "12000", Key.scrollSpeed: "5", Key.scrollReverse: false, Key.deeplinks: false,
    ]

    private static var d: UserDefaults { .standard }
    static func register() { d.register(defaults: defaults) }
    static func string(_ key: String) -> String { d.string(forKey: key) ?? (defaults[key] as? String ?? "") }
    static func bool(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? (defaults[key] as? Bool ?? false) }

    static var saveFolder: URL {
        let s = string(Key.folder)
        return s.isEmpty ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] : URL(fileURLWithPath: s, isDirectory: true)
    }

    static var ocrLanguages: [String] { [string(Key.ocrLanguage), "en-US"].reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    static var lastRect: CGRect? {
        get {
            let p = string(Key.lastRect).split(separator: ",").compactMap { Double($0) }
            return p.count == 4 && p[2] >= 1 && p[3] >= 1 ? CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) : nil
        }
        set { d.set(newValue.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "", forKey: Key.lastRect) }
    }
}

/// Salvar em arquivo (pasta, formato, 1×). Lógica pura, sem janela.
enum CaptureOutput {
    enum Format: String { case png, jpeg }

    /// "auto": foto vira JPEG, tela com poucas cores (texto, interface) fica PNG.
    static func resolve(_ pref: String, png: Data) -> Format {
        switch pref {
        case "png": return .png
        case "jpeg": return .jpeg
        default:
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96] as CFDictionary),
                  let data = thumb.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .png }
            let bpp = max(1, thumb.bitsPerPixel / 8), count = CFDataGetLength(data) / bpp
            var colors = Set<UInt32>()
            for i in 0..<count {
                let o = i * bpp
                colors.insert(UInt32(bytes[o] >> 3) << 16 | UInt32(bytes[o + 1] >> 3) << 8 | UInt32(bytes[min(o + 2, CFDataGetLength(data) - 1)] >> 3))
            }
            return colors.count > 700 ? .jpeg : .png
        }
    }

    static func encode(_ png: Data, format: Format, downscaleBy factor: CGFloat = 1) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if factor > 1, let small = resized(image, by: factor) { image = small }
        let out = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func resized(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) / factor).rounded())), h = max(1, Int((CGFloat(image.height) / factor).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func fileName(_ date: Date, ext: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(f.string(from: date)).\(ext)"
    }

    /// Salva na pasta e devolve o arquivo. Nunca sobrescreve: se o nome existir, acrescenta " 2", " 3"…
    @discardableResult
    static func save(_ png: Data, to folder: URL, formatPref: String, downscaleBy factor: CGFloat, date: Date = Date()) throws -> URL {
        let format = resolve(formatPref, png: png)
        guard let data = encode(png, format: format, downscaleBy: factor) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = format == .png ? "png" : "jpg"
        var url = folder.appendingPathComponent(fileName(date, ext: ext)), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(fileName(date, ext: ext).replacingOccurrences(of: ".\(ext)", with: " \(n).\(ext)")); n += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
