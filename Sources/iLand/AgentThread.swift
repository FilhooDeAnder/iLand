import Foundation

/// Uma ação dentro de uma mensagem da conversa (botão). `kind` é tratado pelo app (AgentController).
struct AgentAction: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let kind: String
    var arg: String?
}

/// Mensagem da conversa com o assistente. Proativa = veio das regras (timer, onde parei, resumo), sem modelo.
struct AgentMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, assistant, proactive }
    var id = UUID().uuidString
    var role: Role
    var text: String
    var ts: Date
    var chips: [String] = []
    var actions: [AgentAction] = []
    var state: String?          // resultado de uma ação ("feito: …") ou "pensando…" no streaming

    init(role: Role, text: String, ts: Date = Date(), actions: [AgentAction] = []) {
        self.role = role; self.text = text; self.ts = ts; self.actions = actions
    }
}

/// Histórico da conversa por dia: ~/Library/Application Support/iLand/brain/threads/AAAA-MM-DD.jsonl (0700/0600).
/// Uma linha por versão da mensagem; ao ler, vale a última versão de cada id (update = acrescentar linha).
struct ThreadStore {
    static let keepDays = 30
    let dir: URL
    let calendar: Calendar
    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = .sortedKeys; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    init(dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLand/brain/threads", isDirectory: true),
         calendar: Calendar = .current) {
        self.dir = dir; self.calendar = calendar
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    func file(for d: Date) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return dir.appendingPathComponent(String(format: "%04d-%02d-%02d.jsonl", c.year ?? 0, c.month ?? 0, c.day ?? 0))
    }

    func append(_ m: AgentMessage) {
        guard let data = try? Self.enc.encode(m) else { return }
        let url = file(for: m.ts)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data + Data("\n".utf8))
        try? h.close()
    }

    func update(_ m: AgentMessage) { append(m) }

    func day(_ d: Date) -> [AgentMessage] {
        guard let text = try? String(contentsOf: file(for: d), encoding: .utf8) else { return [] }
        var order: [String] = [], last: [String: AgentMessage] = [:]
        for line in text.split(separator: "\n") {
            guard let m = try? Self.dec.decode(AgentMessage.self, from: Data(line.utf8)) else { continue }
            if last[m.id] == nil { order.append(m.id) }
            last[m.id] = m
        }
        return order.compactMap { last[$0] }
    }

    func prune(now: Date) {
        guard let limit = calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: now)),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let keep = file(for: limit).lastPathComponent
        for f in files where f.pathExtension == "jsonl" && f.lastPathComponent < keep { try? FileManager.default.removeItem(at: f) }
    }
}

/// Nome de ferramenta do cérebro -> chip legível na mensagem ("olhei seu dia").
enum AgentChips {
    static func label(for tool: String, args: [String: Any]) -> String {
        let name = tool.components(separatedBy: "__").last ?? tool
        switch name {
        case "day_log": return "olhei seu dia"
        case "project_info": return (args["project"] as? String).map { String($0.prefix(40)) } ?? "projeto"
        case "timer_status": return "timer do ClickUp"
        case "memory_query": return "minha memória"
        case "my_tasks": return "suas tasks"
        case "propose_action": return "proposta"
        case "open_project": return "abrir projeto"
        case "remind": return "lembrete"
        default: return name
        }
    }
}
