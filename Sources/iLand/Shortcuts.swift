import Foundation
import AppKit

/// Atalhos do dia a dia. Comandos fixos (nada que o usuário digita vai para um shell) e feedback curto na página.
final class ShortcutsModel: ObservableObject {
    @Published private(set) var message = ""
    @Published var confirmingTrash = false
    @Published var confirmingFinder = false
    private var clearWork: DispatchWorkItem?

    private func say(_ s: String) {
        message = s
        clearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.message = "" }
        clearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    private func run(_ exe: String, _ args: [String], then: @escaping (Int32, String) -> Void = { _, _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Process(); t.executableURL = URL(fileURLWithPath: exe); t.arguments = args
            let out = Pipe(); t.standardOutput = out; t.standardError = FileHandle.nullDevice   // stderr nunca lido: encheria o pipe
            var text = ""
            var code: Int32 = -1
            if (try? t.run()) != nil { text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); t.waitUntilExit(); code = t.terminationStatus }
            DispatchQueue.main.async { then(code, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    func toggleDarkMode() {
        run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode",
                                   "-e", "tell application \"System Events\" to tell appearance preferences to return dark mode"]) { [weak self] code, out in
            self?.say(code == 0 ? (out == "true" ? "Modo escuro ligado" : "Modo claro ligado") : "Não consegui trocar (o macOS pediu permissão?)")
        }
    }

    func toggleDesktopIcons() {
        // Reinicia o Finder: pede confirmação (interrompe cópias e movimentos em andamento).
        guard confirmingFinder else {
            confirmingFinder = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.confirmingFinder = false }
            return
        }
        confirmingFinder = false
        run("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"]) { [weak self] _, out in
            let showing = out != "0" && out.lowercased() != "false"
            self?.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", showing ? "false" : "true"]) { _, _ in
                self?.run("/usr/bin/killall", ["Finder"]) { _, _ in self?.say(showing ? "Ícones da mesa ocultos" : "Ícones da mesa de volta") }
            }
        }
    }

    func emptyTrash() {
        guard confirmingTrash else {
            confirmingTrash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.confirmingTrash = false }
            return
        }
        confirmingTrash = false
        run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"]) { [weak self] code, _ in
            self?.say(code == 0 ? "Lixeira esvaziada" : "Não consegui esvaziar a lixeira")
        }
    }

    /// Apaga a tela; só tranca se "Exigir senha" estiver ligado nos Ajustes (Tela Bloqueada).
    func lockScreen() { run("/usr/bin/pmset", ["displaysleepnow"]) { [weak self] _, _ in self?.say("Tela apagada (para trancar, ligue \"Exigir senha\" em Tela Bloqueada)") } }

    // MARK: cor e texto da tela (a janela do iLand recolhe antes, para não aparecer no print)
    func pickColor() {
        NotificationCenter.default.post(name: .ilandCollapse, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ScreenTools.pickColor { [weak self] rgb in
                guard let rgb else { return self?.say("Seleção de cor cancelada") ?? () }
                let pb = NSPasteboard.general; pb.clearContents(); pb.setString(rgb.hex, forType: .string)
                self?.say("Cor copiada: \(rgb.hex)  ·  \(rgb.css)")
            }
        }
    }

    func copyTextFromScreen() {
        NotificationCenter.default.post(name: .ilandCollapse, object: nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("iland-ocr-\(UUID().uuidString).png")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ScreenTools.captureArea(to: file) { [weak self] ok in
                guard ok else { return self?.say("Captura cancelada (ou falta permissão de gravação de tela)") ?? () }
                DispatchQueue.global(qos: .userInitiated).async {
                    let text = ScreenTools.recognizeText(in: file)
                    try? FileManager.default.removeItem(at: file)
                    DispatchQueue.main.async {
                        guard !text.isEmpty else { return self?.say("Não achei texto na área") ?? () }
                        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string)
                        self?.say("Texto copiado (\(text.count) caracteres)")
                    }
                }
            }
        }
    }
}
