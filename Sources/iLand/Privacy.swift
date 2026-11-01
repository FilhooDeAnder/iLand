import Foundation

/// O que o sensor sabe da janela da frente, antes de decidir se pode gravar o título.
struct PrivacyInput {
    var bundleID: String
    var title: String
    var isBrowser: Bool
    var browserMode: String?        // Chrome/Arc: "normal" | "incognito"; nil = não deu para saber
    var secureInput: Bool           // IsSecureEventInputEnabled (global: pode ser o Terminal com "Secure Keyboard Entry")
    var focusedIsSecureField: Bool  // AXSecureTextField em foco
    var paused: Bool
    var extraBlockedApps: Set<String> = []
}

/// Decide, antes de gravar ou ler qualquer coisa, se o trecho é privado. Privado guarda app e tempo, nunca o título.
/// Lógica pura: teste em Tests/Unit/test_privacy.swift.
enum PrivacyGate {
    enum Verdict: Equatable { case ok(String), `private`(String) }

    static let blockedApps: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                                           "com.apple.keychainaccess", "com.apple.Passwords"]
    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
                                        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera"]
    /// Nome de arquivo sensível no título (".env", ".env.local", ".envrc", chaves, credenciais).
    static let sensitiveFile = #"(?i)(^|[\s/\\(\[])(\.env(\.[\w.-]+|rc)?|id_rsa|id_ed25519|credentials|secrets(\.[\w]+)?|[\w.-]+\.(pem|p12|key))(?=$|[\s—–\-:)\]])"#

    /// Navegadores que dizem pelo AppleScript se a janela da frente é anônima.
    static let modeAware: Set<String> = ["com.google.Chrome", "company.thebrowser.Browser"]

    static func isBrowser(_ bundleID: String) -> Bool { browsers.contains(bundleID) }

    static func decide(_ i: PrivacyInput) -> Verdict {
        if i.paused { return .private("pausado") }
        if blockedApps.contains(i.bundleID) || i.extraBlockedApps.contains(i.bundleID) { return .private("app bloqueado") }
        if i.secureInput { return .private("digitação segura") }
        if i.focusedIsSecureField { return .private("campo de senha") }
        if i.isBrowser {
            // Só Chrome e Arc dizem o modo da janela (AppleScript); nos outros não dá para saber se é anônima.
            guard modeAware.contains(i.bundleID), i.browserMode == "normal" else { return .private("navegador anônimo ou sem modo conhecido") }
            if i.title.localizedCaseInsensitiveContains("bitbucket") { return .private("Bitbucket") }
        }
        if i.title.range(of: sensitiveFile, options: .regularExpression) != nil { return .private("arquivo sensível") }
        return .ok(Redact.text(i.title))
    }
}
