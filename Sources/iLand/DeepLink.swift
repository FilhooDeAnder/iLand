import Foundation

/// iland://grab/area|fullscreen|window|anywindow|repeat|scroll|ocr  ?delay=3&then=thumbnail|editor|copy|save|upload
/// iland://open/library|clipboard. Só funciona com "Deep links" ligado nos Ajustes (vem desligado).
enum DeepLink {
    struct Command: Equatable {
        enum Kind: Equatable { case grab(CaptureMode), text, library, clipboard }
        var kind: Kind
        var delay = 0
        var then: String?
    }

    static func parse(_ url: URL) -> Command? {
        guard url.scheme == "iland", let host = url.host else { return nil }
        let name = url.pathComponents.dropFirst().first?.lowercased() ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ k: String) -> String? { query.first { $0.name == k }?.value }
        let delay = min(max(Int(value("delay") ?? "") ?? 0, 0), 60)
        let then = value("then").flatMap { ["thumbnail", "editor", "copy", "save", "upload"].contains($0) ? $0 : nil }
        switch (host, name) {
        case ("grab", "area"): return Command(kind: .grab(.area), delay: delay, then: then)
        case ("grab", "fullscreen"): return Command(kind: .grab(.fullscreen), delay: delay, then: then)
        case ("grab", "window"): return Command(kind: .grab(.window), delay: delay, then: then)
        case ("grab", "anywindow"): return Command(kind: .grab(.anyWindow), delay: delay, then: then)
        case ("grab", "repeat"): return Command(kind: .grab(.repeatArea), delay: delay, then: then)
        case ("grab", "scroll"): return Command(kind: .grab(.scroll), delay: delay, then: then)
        case ("grab", "ocr"): return Command(kind: .text)
        case ("open", "library"): return Command(kind: .library)
        case ("open", "clipboard"): return Command(kind: .clipboard)
        default: return nil
        }
    }

    static func handle(_ url: URL, model: CaptureModel) {
        guard CapturePrefs.bool(CapturePrefs.Key.deeplinks) else { Toast.show("Ligue os deep links nos Ajustes (aba Captura)."); return }
        guard let cmd = parse(url) else { return }
        switch cmd.kind {
        case .grab(let mode): model.capture(mode, delay: cmd.delay, then: cmd.then)
        case .text: model.captureText()
        case .library: model.showLibrary()
        case .clipboard: model.openClipboardImage()
        }
    }
}
