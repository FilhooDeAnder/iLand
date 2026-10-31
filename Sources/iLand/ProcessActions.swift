import SwiftUI
import AppKit

/// "iniciado por sh ← claude ← Claude": cada nome com janela é clicável e leva ao app (e à mesa dele).
struct ChainView: View {
    let chain: [Origin.Link]
    var tty = ""
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Text(compact ? "←" : "iniciado por").foregroundColor(Color.white.opacity(0.55))
            ForEach(Array(chain.enumerated()), id: \.offset) { i, link in
                if i > 0 { Text("←").foregroundColor(Color.white.opacity(0.55)) }
                if let app = AppFocus.gui(from: chain[i...]) {
                    Button(link.name) { AppFocus.go(to: app, tty: tty) }
                        .buttonStyle(.plain)
                        .foregroundColor(.white).underline()
                        .help("Abrir \(app.localizedName ?? link.name)")
                } else {
                    Text(link.name).foregroundColor(Color.white.opacity(0.8))
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

enum AppFocus {
    /// Primeiro item da cadeia (a partir do clicado) que é um app com janela.
    static func gui(from links: ArraySlice<Origin.Link>) -> NSRunningApplication? {
        for l in links {
            if let app = NSRunningApplication(processIdentifier: l.pid), app.activationPolicy == .regular { return app }
        }
        return nil
    }

    /// Abre o app. Se for Terminal ou iTerm e soubermos o tty, seleciona a aba exata onde o processo roda.
    static func go(to app: NSRunningApplication, tty: String = "") {
        app.unhide()
        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        if let script = focusScript(bundle: app.bundleIdentifier, tty: tty) {
            DispatchQueue.global().async {
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
                if let err { NSLog("iLand: AppleScript falhou: \(err)") }
            }
        }
        NotificationCenter.default.post(name: .ilandCollapse, object: nil)
    }

    private static func focusScript(bundle: String?, tty: String) -> String? {
        guard tty.range(of: "^ttys[0-9]+$", options: .regularExpression) != nil else { return nil }
        let dev = "/dev/" + tty
        switch bundle {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(dev)" then
                    set selected of t to true
                    set index of w to 1
                  end if
                end repeat
              end repeat
              activate
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(dev)" then
                      select t
                      select s
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """
        default:
            return nil
        }
    }
}

extension Notification.Name { static let ilandCollapse = Notification.Name("iland.collapse") }

/// Encerra com confirmação. App com janela recebe pedido educado de fechar; o resto leva SIGTERM (e SIGKILL se não sair).
struct KillButton: View {
    let targets: [ProcTarget]
    let quitApp: NSRunningApplication?
    @ObservedObject var monitor: SystemMonitor
    @State private var confirming = false

    var body: some View {
        Button(confirming ? "Confirmar?" : "Encerrar") {
            guard confirming else { confirming = true; return }
            if let quitApp { quitApp.terminate() } else { monitor.terminate(targets) }
        }
        .buttonStyle(CapsuleStyle(tint: .red))
    }
}
