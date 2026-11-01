import Foundation

/// Em qual projeto (pasta com .git) a pessoa está. Lógica pura: teste em Tests/Unit/test_projects.swift.
enum ProjectResolver {
    /// Ancestral com `.git` mais fundo (repositório dentro de repositório, como em ~/workspace).
    /// Aceita caminho ou URL `file://` (o kAXDocumentAttribute vem assim). `exists(p)` = existe `p/.git`.
    static func root(forPath raw: String, exists: (String) -> Bool) -> String? {
        var path = raw
        if raw.hasPrefix("file://") { path = URL(string: raw)?.path ?? String(raw.dropFirst(7)) }
        guard path.hasPrefix("/") else { return nil }
        var cur = (path as NSString).standardizingPath
        while cur != "/" && !cur.isEmpty {
            if exists(cur) { return cur }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Pasta aberta, pelo título do Cursor/VS Code: "arquivo — pasta" (às vezes "… — Cursor"). Workspace = sem pasta.
    static func folderName(fromTitle title: String) -> String? {
        var parts = title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let last = parts.last, ["Cursor", "Visual Studio Code", "Code"].contains(last) { parts.removeLast() }
        guard let name = parts.last, !name.hasSuffix("(Workspace)") else { return nil }
        return name
    }

    /// Nome de pasta -> caminho do repositório. Nome repetido (há vários "api"): o mais recente visto por caminho;
    /// sem pista, "<nome> (?)". `recent`: caminhos de trechos anteriores, do mais antigo ao mais novo.
    static func match(name: String, repos: [String], recent: [String]?) -> String? {
        let hits = repos.filter { ($0 as NSString).lastPathComponent == name }
        if hits.count == 1 { return hits[0] }
        if hits.isEmpty { return nil }
        if let r = recent?.last(where: { hits.contains($0) }) { return r }
        return "\(name) (?)"
    }

    /// Terminal: o título é "pasta — processo — tamanho"; a pasta só vale se casar com um projeto conhecido.
    static func terminalFolder(fromTitle title: String) -> String? {
        let parts = title.components(separatedBy: " — ")
        guard parts.count >= 2, let f = parts.first?.trimmingCharacters(in: .whitespaces), !f.isEmpty else { return nil }
        return f
    }

    /// Nome curto para a tela.
    static func display(_ project: String) -> String { project.hasPrefix("/") ? (project as NSString).lastPathComponent : project }
}

/// Sessões do Claude Code (~/.claude/projects/*/*.jsonl): pasta, hora da última atividade e o último pedido.
enum ClaudeSessions {
    struct Session: Equatable {
        let cwd: String
        let timestamp: Date
        let entrypoint: String
        let lastPrompt: String?   // já mascarado (vem cru e cortado em ~200 caracteres)
    }

    /// Só sessões abertas pela pessoa (editor, app, terminal); `sdk-cli` são automações em segundo plano.
    static let humanEntrypoints: Set<String> = ["claude-vscode", "claude-desktop", "cli"]

    /// Lê o fim de um arquivo (a 1ª linha pode estar cortada e é ignorada por não ser JSON válido).
    static func latest(tail: String) -> Session? {
        var cwd: String?, ts: Date?, entry: String?, prompt: String?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for line in tail.split(separator: "\n").reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = o["type"] as? String
            if type == "last-prompt", prompt == nil { prompt = o["lastPrompt"] as? String; continue }
            guard type == "user" || type == "assistant", (o["isSidechain"] as? Bool) != true,
                  let e = o["entrypoint"] as? String, let c = o["cwd"] as? String, let t = o["timestamp"] as? String,
                  let d = iso.date(from: t) ?? isoPlain.date(from: t) else { continue }
            if cwd == nil { cwd = c; ts = d; entry = e }
        }
        guard let cwd, let ts, let entry, humanEntrypoints.contains(entry) else { return nil }
        return Session(cwd: cwd, timestamp: ts, entrypoint: entry, lastPrompt: prompt.map(Redact.text))
    }

    /// Sessões mexidas nas últimas 24 h (só os últimos 256 KB de cada arquivo; há arquivos de 65 MB).
    static func recent(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
                       now: Date = Date()) -> [Session] {
        guard Prefs.readSessions else { return [] }   // a pessoa desligou em Ajustes › Privacidade
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Session] = []
        for d in dirs {
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(m) < 86400, let h = try? FileHandle(forReadingFrom: f) else { continue }
                defer { try? h.close() }
                let size = (try? h.seekToEnd()) ?? 0
                try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
                if let data = try? h.readToEnd(), let s = latest(tail: String(decoding: data, as: UTF8.self)) { out.append(s) }
            }
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }
}

extension ClaudeSessions {
    /// Pastas de trabalho das sessões dos últimos `days` dias (lê só o começo de cada arquivo).
    static func cwds(days: Int, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) -> [String] {
        guard Prefs.readSessions else { return [] }
        var out = Set<String>()
        for f in SessionFiles.recent(under: root, days: days) {
            for line in SessionFiles.head(f).split(separator: "\n") {
                if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let c = o["cwd"] as? String { out.insert(c); break }
            }
        }
        return Array(out)
    }
}

/// Sessões do Codex (~/.codex/sessions/AAAA/MM/DD/*.jsonl): pasta de trabalho e os limites de uso da conta.
enum CodexSessions {
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    /// A 1ª linha é `session_meta` com `payload.cwd`.
    static func cwds(days: Int) -> [String] {
        guard Prefs.readSessions else { return [] }
        var out = Set<String>()
        for f in SessionFiles.recent(under: root, days: days) {
            guard let line = SessionFiles.head(f).split(separator: "\n").first,
                  let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let c = (o["payload"] as? [String: Any])?["cwd"] as? String else { continue }
            out.insert(c)
        }
        return Array(out)
    }

    /// Último `rate_limits` gravado num evento `token_count` (o Codex grava a cada resposta): primary = janela de 5 h,
    /// secondary = 7 dias, com `used_percent` e `resets_at` (segundos). Devolve também a hora do arquivo, para saber se está velho.
    static func rateLimits(now: Date = Date()) -> (primary: [String: Any]?, secondary: [String: Any]?, at: Date)? {
        let files = SessionFiles.recent(under: root, days: 8).sorted { SessionFiles.modified($0) > SessionFiles.modified($1) }
        for f in files.prefix(5) {
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
            for line in tail.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let rl = (o["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
                return (rl["primary"] as? [String: Any], rl["secondary"] as? [String: Any], SessionFiles.modified(f))
            }
        }
        return nil
    }
}

/// Arquivos .jsonl de sessão (Claude Code e Codex), mexidos nos últimos dias.
enum SessionFiles {
    static func modified(_ f: URL) -> Date { (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

    static func recent(under root: URL, days: Int, now: Date = Date()) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let f as URL in e where f.pathExtension == "jsonl" && now.timeIntervalSince(modified(f)) < Double(days) * 86400 { out.append(f) }
        return out
    }

    /// Primeiros 64 KB (a última linha pode vir cortada e não vira JSON válido).
    static func head(_ f: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: f) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: 65_536)) ?? Data(), as: UTF8.self)
    }
}
