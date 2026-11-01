import Foundation

/// "Onde parei" (assistente, fase 2): ao voltar a um projeto depois de 1 h, junta as pistas guardadas aqui no Mac
/// (último pedido ao Claude, "Em progresso" do ESTADO.md, arquivos alterados no git). Não chama o Claude.
/// Lógica pura + leitura de arquivos; teste em Tests/Unit/test_resume.swift.
enum Resume {
    static let gap: TimeInterval = 3600
    static let lookback: TimeInterval = 7 * 86400

    struct Info: Equatable {
        let project: String
        let lastPrompt: String?
        let inProgress: String?
        let changedFiles: Int

        var lines: [String] {
            var out: [String] = []
            if let p = lastPrompt { out.append("Último pedido ao Claude: \(p)") }
            if let e = inProgress { out.append("Em progresso: \(e)") }
            if changedFiles > 0 { out.append("\(changedFiles) arquivo\(changedFiles == 1 ? "" : "s") alterado\(changedFiles == 1 ? "" : "s")") }
            return out.isEmpty ? ["Sem pistas guardadas deste projeto."] : out
        }
    }

    /// Avisa se o projeto foi visto antes (nos últimos 7 dias) e ficou 1 h ou mais sem trecho.
    static func shouldNotify(lastSeen: Date?, now: Date) -> Bool {
        guard let l = lastSeen else { return false }
        let away = now.timeIntervalSince(l)
        return away >= gap && away <= lookback
    }

    /// 1º item da seção "## Em progresso" (mascarado, até 200 caracteres).
    static func inProgress(fromEstado text: String) -> String? {
        var inside = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { if inside { return nil }; inside = l.lowercased().hasPrefix("## em progresso"); continue }
            if inside, l.hasPrefix("- ") { return String(Redact.text(String(l.dropFirst(2))).prefix(200)) }
        }
        return nil
    }

    static func changedFiles(porcelain: String) -> Int { porcelain.split(separator: "\n").filter { !$0.isEmpty }.count }

    /// Monta as pistas de um projeto (roda fora da main: lê arquivos e chama git).
    static func gather(project: String, sessions: [ClaudeSessions.Session]) -> Info {
        let prompt = sessions.last { $0.cwd == project || $0.cwd.hasPrefix(project + "/") }?.lastPrompt
        let estado = (try? String(contentsOfFile: project + "/docs/ESTADO.md", encoding: .utf8)).flatMap(inProgress(fromEstado:))
        let changed = git(["-C", project, "status", "--porcelain"], in: project).map(changedFiles(porcelain:)) ?? 0
        return Info(project: project, lastPrompt: prompt, inProgress: estado, changedFiles: changed)
    }

    /// `git` com argumentos separados (sem shell), 10 s no máximo. nil se não é repositório ou o git falhou.
    static func git(_ args: [String], in project: String) -> String? {
        guard FileManager.default.fileExists(atPath: project + "/.git") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Quando avisar o "onde parei": só depois de 5 min SEGUIDOS no projeto (passagens rápidas por outras janelas são comuns) e se a
/// última estadia de verdade nele (também ≥ 5 min) foi há 1 h ou mais. Passagem rápida não conta como visita.
/// Lógica pura: teste em Tests/Unit/test_resume.swift.
struct ResumeGate {
    static let dwell: TimeInterval = 300
    private(set) var lastSeen: [String: Date]          // fim da última estadia ≥ 5 min (ou do log, no início)
    private var current: String?
    private var since = Date.distantPast
    private var gapBefore: Date?                       // lastSeen do projeto atual quando a estadia começou
    private var notified = false

    init(lastSeen: [String: Date]) { self.lastSeen = lastSeen }

    /// Devolve o projeto a avisar agora (uma vez por estadia), ou nil.
    mutating func observe(project: String?, now: Date) -> String? {
        if project != current {
            current = project; since = now; notified = false
            gapBefore = project.flatMap { lastSeen[$0] }
            return nil
        }
        guard let p = project, now.timeIntervalSince(since) >= Self.dwell else { return nil }
        defer { lastSeen[p] = now }                    // estadia de verdade: passa a contar como visita
        guard !notified else { return nil }
        notified = true
        return Resume.shouldNotify(lastSeen: gapBefore, now: since) ? p : nil
    }
}
