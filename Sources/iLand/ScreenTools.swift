import Foundation
import AppKit
import Vision

/// Formatos de cor para copiar (lógica pura).
struct RGB: Equatable {
    let r: Int, g: Int, b: Int   // 0...255

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    var css: String { "rgb(\(r), \(g), \(b))" }
    var swiftUI: String { String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", Double(r) / 255, Double(g) / 255, Double(b) / 255) }
    var hsl: String {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf), l = (mx + mn) / 2, d = mx - mn
        var h = 0.0, s = 0.0
        if d > 0 {
            s = d / (1 - abs(2 * l - 1))
            switch mx {
            case rf: h = ((gf - bf) / d).truncatingRemainder(dividingBy: 6)
            case gf: h = (bf - rf) / d + 2
            default: h = (rf - gf) / d + 4
            }
            h *= 60; if h < 0 { h += 360 }
        }
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }
}

/// Seleção de cor na tela, texto da tela (OCR offline) e captura de área.
enum ScreenTools {
    static func pickColor(_ done: @escaping (RGB?) -> Void) {
        NSColorSampler().show { c in
            guard let c = c?.usingColorSpace(.sRGB) else { return done(nil) }
            func v(_ x: CGFloat) -> Int { Int((x * 255).rounded()) }
            done(RGB(r: v(c.redComponent), g: v(c.greenComponent), b: v(c.blueComponent)))
        }
    }

    /// `screencapture` com estes argumentos. false se cancelou ou o macOS negou a gravação de tela.
    static func screencapture(_ args: [String], to url: URL, _ done: @escaping (Bool) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = args + [url.path]
        DispatchQueue.global(qos: .userInitiated).async {
            do { try task.run(); task.waitUntilExit() } catch { return DispatchQueue.main.async { done(false) } }
            let ok = FileManager.default.fileExists(atPath: url.path) && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// `screencapture -i` (você seleciona a área).
    static func captureArea(to url: URL, _ done: @escaping (Bool) -> Void) { screencapture(["-i", "-x"], to: url, done) }

    /// Reconhece o texto da imagem (português e inglês), linha por linha.
    static func recognizeText(in url: URL) -> String {
        guard let data = try? Data(contentsOf: url), let img = NSImage(data: data), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["pt-BR", "en-US"]
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
