import Foundation

/// Preferências do iLand (UserDefaults). As views usam @AppStorage com as mesmas chaves; o resto do código lê por aqui.
enum Prefs {
    enum Key {
        static let earsShowUsage = "earsShowUsage"      // antigo (até 2026-10-18): virou earsSource
        static let hoverEars = "hoverEars"              // mouse sobre o notch abre as orelhas
        static let shelfOnDrag = "shelfOnDrag"          // arrastar arquivo até o notch abre a prateleira
        static let quickHideDelay = "quickHideDelay"    // segundos até a vista rápida recolher depois que o mouse sai
        static let hiddenPages = "hiddenPages"          // páginas escondidas da vista rápida ("2,5")
        static let pageOrder = "pageOrder"              // ordem das páginas ("0,2,1,...")
        static let claudeModel = "claudeModel"          // haiku | sonnet
        static let usageFromAPI = "usageFromAPI"        // consultar a API do Claude (usa o Keychain)
        static let activityPaused = "activityPaused"    // assistente: Pausar (não registra nada além de app e tempo)
        static let summaryDay = "summaryDay"            // dia (AAAA-MM-DD) do último resumo automático
        static let axPrompted = "axPrompted"            // já pediu a permissão de Acessibilidade uma vez
        static let assistantFrom = "assistantFrom"      // hora em que o assistente começa (registro, vigia do timer, avisos)
        static let assistantTo = "assistantTo"          // hora em que ele para (exclusiva)
        static let machines = "machines"                // apelidos SSH das máquinas monitoradas ("web-1,db")
        static let onboarded = "onboarded"              // já passou pelo assistente de configuração
        static let userName = "userName"                // como o assistente chama a pessoa
        static let userRole = "userRole"                // o que ela faz (uma linha, entra no prompt)
        static let editor = "editor"                    // bundle id do editor de código
        static let terminal = "terminal"                // bundle id do terminal
        static let projectRoots = "projectRoots"        // pastas extras de projetos, uma por linha
        static let earsSource = "earsSource"            // o que as orelhas mostram: claude | codex | none
        static let roleAssistant = "roleAssistant"      // "provedor:modelo" de cada papel (ver Providers.swift)
        static let roleSummary = "roleSummary"
        static let roleExplain = "roleExplain"
        static let roleQuick = "roleQuick"
        static let readSessions = "readSessions"        // ler as sessões do Claude Code e do Codex (pasta, horário, último pedido)
    }

    static let defaults: [String: Any] = [
        Key.earsShowUsage: true, Key.hoverEars: true, Key.shelfOnDrag: true,
        Key.quickHideDelay: 1.2, Key.hiddenPages: "", Key.pageOrder: "", Key.claudeModel: "haiku", Key.usageFromAPI: true,
        Key.machines: "", Key.userName: "", Key.userRole: "", Key.editor: "", Key.terminal: "com.apple.Terminal",
        Key.projectRoots: "", Key.earsSource: "claude", Key.readSessions: true,
        Key.roleAssistant: "claude:sonnet", Key.roleSummary: "claude:haiku", Key.roleExplain: "claude:haiku", Key.roleQuick: "claude:haiku",
        Key.assistantFrom: 7, Key.assistantTo: 19,
    ]

    static func register() {
        migrateOldDomain()
        UserDefaults.standard.register(defaults: defaults)
    }

    /// O bundle id mudou de com.iland.app para br.com.loop4.iland (2026-10-18). Na primeira abertura copia as
    /// preferências antigas, uma vez. Quem já tinha máquinas ou expediente salvos não passa pelo assistente de novo.
    static func migrateOldDomain() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedOldDomain") else { return }
        d.set(true, forKey: "migratedOldDomain")
        guard let old = d.persistentDomain(forName: "com.iland.app"), !old.isEmpty else { return }
        for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        if old[Key.earsShowUsage] as? Bool == false { d.set("none", forKey: Key.earsSource) }
        // Quem vem da versão antiga já usava o app: não passa pelo assistente de configuração.
        d.set(true, forKey: Key.onboarded)
    }

    /// Ler as sessões do Claude Code e do Codex. Sem valor salvo = sim (o padrão).
    static var readSessions: Bool { UserDefaults.standard.object(forKey: Key.readSessions) as? Bool ?? true }

    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }

    /// Nome da pessoa para o prompt e para a janela; vazio vira "você".
    static var userName: String {
        let n = string(Key.userName).trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "você" : String(n.prefix(40))
    }

    /// Pastas extras de projetos (uma por linha), só as que existem.
    static var projectRoots: [URL] {
        string(Key.projectRoots).split(separator: "\n").map { URL(fileURLWithPath: ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath) }
            .filter { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &dir) && dir.boolValue }
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var quickHideDelay: TimeInterval { min(max(UserDefaults.standard.double(forKey: Key.quickHideDelay), 0.3), 10) }

    static var claudeModel: String {
        let m = UserDefaults.standard.string(forKey: Key.claudeModel) ?? "haiku"
        return m == "sonnet" ? "sonnet" : "haiku"   // só valores conhecidos vão para a linha de comando
    }

    /// Páginas escondidas (o Resumo nunca esconde). Texto inválido vira conjunto vazio.
    static func hiddenPages(_ csv: String) -> Set<Int> {
        Set(csv.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 })
    }
    static func csv(_ pages: Set<Int>) -> String { pages.sorted().map(String.init).joined(separator: ",") }
    /// Ordem das páginas: o texto salvo (sem repetidos nem valores inválidos) e o que faltar no fim, na ordem original.
    /// O Resumo (0) é sempre o primeiro. `count` = quantas páginas existem.
    static func order(_ csv: String, count: Int) -> [Int] {
        var seen = Set<Int>([0]), out = [0]
        for p in csv.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) where (1..<count).contains(p) && seen.insert(p).inserted { out.append(p) }
        for p in 1..<count where seen.insert(p).inserted { out.append(p) }
        return out
    }
    static func orderCSV(_ order: [Int]) -> String { order.map(String.init).joined(separator: ",") }

    /// Expediente do assistente (padrão 7h–19h). Fora dele: sem registro, sem vigia do timer e sem avisos;
    /// a conversa continua respondendo se a pessoa perguntar.
    static func assistantActive(_ now: Date = Date(), calendar: Calendar = .current, from: Int? = nil, to: Int? = nil) -> Bool {
        let f = from ?? UserDefaults.standard.integer(forKey: Key.assistantFrom)
        let t = to ?? UserDefaults.standard.integer(forKey: Key.assistantTo)
        let h = calendar.component(.hour, from: now)
        return f < t ? (h >= f && h < t) : (h >= f || h < t)   // f > t: expediente que atravessa a meia-noite
    }

    /// Páginas escondidas. Sem máquinas (ou túneis) cadastrados, a página deles também some.
    static var hidden: Set<Int> {
        var h = hiddenPages(UserDefaults.standard.string(forKey: Key.hiddenPages) ?? "")
        if machines.isEmpty { h.insert(9) }   // 9 = QuickPage.machines (Prefs compila sozinho no test_prefs)
        if string("tunnels").isEmpty { h.insert(11) }   // 11 = QuickPage.tunnels; chave do TunnelStore, vazia sem túneis
        return h
    }

    /// Hosts SSH (apelido do ~/.ssh/config ou usuario@endereco). Só letras, números, ponto, hífen e sublinhado (vão como argumento do ssh); sem repetir.
    static var machines: [String] {
        var seen = Set<String>()
        return (UserDefaults.standard.string(forKey: Key.machines) ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isValidHost($0) && seen.insert($0).inserted }
    }

    /// Vai como argumento do ssh: sem espaço, aspas nem "-" no começo (não vira opção). "usuario@host" é aceito.
    static func isValidHost(_ h: String) -> Bool {
        h.range(of: "^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}(@[A-Za-z0-9._][A-Za-z0-9._-]{0,127})?$", options: .regularExpression) != nil
    }
}
