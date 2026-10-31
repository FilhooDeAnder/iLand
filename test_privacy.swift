// Uso: swiftc -parse-as-library Sources/iLand/SuspectTracker.swift Sources/iLand/Privacy.swift test_privacy.swift -o /tmp/t_privacy && /tmp/t_privacy
// Títulos inventados no formato real dos apps.
import Foundation

@main struct PrivacyCheck {
    static func main() {
        // máscara
        let t = Redact.text("falha de dev@example.com token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln cpf 12345678901 pedido 1234")
        assert(!t.contains("dev@example") && !t.contains("eyJhbGci") && !t.contains("12345678901"), t)
        assert(t.contains("pedido 1234"), "número curto fica: \(t)")
        assert(Redact.text("node --token abc123") == "node --token •••", "regras antigas valem")

        func gate(_ title: String, app: String = "com.todesktop.230313mzl4w4u92", browser: Bool = false, mode: String? = nil,
                  secure: Bool = false, field: Bool = false, paused: Bool = false) -> PrivacyGate.Verdict {
            PrivacyGate.decide(PrivacyInput(bundleID: app, title: title, isBrowser: browser, browserMode: mode,
                                            secureInput: secure, focusedIsSecureField: field, paused: paused))
        }
        func isPrivate(_ v: PrivacyGate.Verdict) -> Bool { if case .private = v { return true }; return false }

        assert(gate("Machines.swift — iLand") == .ok("Machines.swift — iLand"))
        assert(gate("README.md — bitbucket") == .ok("README.md — bitbucket"), "repo local chamado bitbucket passa")
        for f in [".env — api-demo", ".env.local — crm", ".envrc — x", "id_rsa — ssh", "server.pem — x", "credentials — aws",
                  "cert.p12 — x", "private.key — x", "secrets.yaml — x"] {
            assert(isPrivate(gate(f)), f)
        }
        assert(!isPrivate(gate("environment.ts — app")), "não é .env")
        assert(isPrivate(gate("Pull request #12 - Bitbucket", app: "com.google.Chrome", browser: true, mode: "normal")))
        assert(gate("ClickUp", app: "com.google.Chrome", browser: true, mode: "normal") == .ok("ClickUp"))
        assert(isPrivate(gate("ClickUp", app: "com.google.Chrome", browser: true, mode: "incognito")))
        assert(isPrivate(gate("ClickUp", app: "com.google.Chrome", browser: true, mode: nil)), "modo desconhecido = privado")
        assert(isPrivate(gate("Apple", app: "com.apple.Safari", browser: true, mode: nil)))
        assert(gate("ClickUp", app: "company.thebrowser.Browser", browser: true, mode: "normal") == .ok("ClickUp"), "Arc normal")
        assert(isPrivate(gate("ClickUp", app: "company.thebrowser.Browser", browser: true, mode: "incognito")), "Arc anônimo")
        assert(isPrivate(gate("PR - Bitbucket", app: "company.thebrowser.Browser", browser: true, mode: "normal")))
        assert(isPrivate(gate("Cofre", app: "com.1password.1password")))
        assert(isPrivate(gate("Login", app: "com.apple.keychainaccess")))
        assert(isPrivate(gate("zsh", app: "com.apple.Terminal", secure: true)))
        assert(isPrivate(gate("Login", field: true)))
        assert(isPrivate(gate("Machines.swift — iLand", paused: true)))
        assert(gate("mail de dev@example.com — x") == .ok("mail de [email] — x"), "título passa pela máscara")
        assert(PrivacyGate.isBrowser("com.google.Chrome") && PrivacyGate.isBrowser("com.apple.Safari") && !PrivacyGate.isBrowser("com.apple.Terminal"))
        print("ok")
    }
}
