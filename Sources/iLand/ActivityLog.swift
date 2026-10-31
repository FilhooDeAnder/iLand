import Foundation

/// Um pedaço contínuo de tempo num app/janela/projeto. Privado = sem título (só app, tempo e, se veio de caminho, projeto).
struct Segment: Codable, Equatable {
    var start: Date
    var end: Date
    var app: String
    var title: String?
    var project: String?
    var privateReason: String?
    var seconds: TimeInterval { end.timeIntervalSince(start) }
}

/// O que o sensor viu agora.
struct Sample {
    var app: String
    var title: String?
    var project: String?
    var privateReason: String?
    var lastInput: Date
}

/// Junta amostras em trechos. Lógica pura (relógio e calendário injetados): teste em test_activity.swift.
struct ActivityTracker {
    static let idleAfter: TimeInterval = 300
    private(set) var open: Segment?
    let calendar: Calendar

    init(calendar: Calendar = .current) { self.calendar = calendar }

    /// Devolve os trechos que fecharam. Parado há 5 min: fecha no último input (não na hora em que percebeu).
    mutating func observe(_ s: Sample, now: Date) -> [Segment] {
        var out: [Segment] = []
        if now.timeIntervalSince(s.lastInput) >= Self.idleAfter {
            if open != nil { out += close(at: s.lastInput) }
            return out
        }
        if var o = open, !calendar.isDate(o.start, inSameDayAs: now) {   // virou o dia: corta na meia-noite
            let midnight = calendar.startOfDay(for: now)
            o.end = midnight
            out.append(o)
            open?.start = midnight
        }
        if let o = open, o.app == s.app, o.title == s.title, o.project == s.project, o.privateReason == s.privateReason {
            open?.end = now
            return out
        }
        if open != nil { out += close(at: now) }
        open = Segment(start: now, end: now, app: s.app, title: s.title, project: s.project, privateReason: s.privateReason)
        return out
    }

    /// Fecha o trecho aberto (sono, bloqueio de tela, troca de usuário, parado).
    mutating func close(at t: Date) -> [Segment] {
        guard var o = open else { return [] }
        o.end = max(o.start, t)
        open = nil
        return [o]
    }
}

/// Tempo por projeto no dia.
enum ActivitySummary {
    struct Row: Equatable { let project: String; var seconds: TimeInterval; var privateSeconds: TimeInterval }
    static let inheritUnder: TimeInterval = 120

    /// Sem projeto e < 2 min entre dois trechos do mesmo projeto (uma olhada no Chrome): conta para esse projeto.
    /// Sem projeto: o nome do app; privado sem projeto: "privado".
    /// Tela bloqueada / protetor de tela: não é trabalho (a 1ª versão contou 2h49 de "privado" assim).
    static let away: Set<String> = ["loginwindow", "ScreenSaverEngine"]

    static func byProject(_ all: [Segment]) -> [Row] {
        var rows: [String: Row] = [:]
        let segs = all.filter { !away.contains($0.app) }
        for (i, s) in segs.enumerated() {
            var key = s.project
            if key == nil, s.seconds < inheritUnder, i > 0, i + 1 < segs.count,
               let p = segs[i - 1].project, segs[i + 1].project == p { key = p }
            let k = key ?? (s.privateReason != nil ? "privado" : s.app)
            var r = rows[k] ?? Row(project: k, seconds: 0, privateSeconds: 0)
            r.seconds += s.seconds
            if s.privateReason != nil { r.privateSeconds += s.seconds }
            rows[k] = r
        }
        return rows.values.sorted { $0.seconds > $1.seconds }
    }
}

/// Arquivos do log: activity/AAAA-MM-DD.jsonl (um trecho por linha) e current.json (o trecho aberto, para crash).
/// Pasta 0700, arquivos 0600; trechos com mais de 30 dias são apagados.
struct ActivityStore {
    static let keepDays = 30
    let dir: URL
    let calendar: Calendar

    init(dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iLand/activity", isDirectory: true),
         calendar: Calendar = .current) {
        self.dir = dir
        self.calendar = calendar
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = .sortedKeys; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    func file(for day: Date) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return dir.appendingPathComponent(String(format: "%04d-%02d-%02d.jsonl", c.year ?? 0, c.month ?? 0, c.day ?? 0))
    }

    func append(_ segs: [Segment]) {
        for s in segs where s.seconds >= 1 {
            guard let data = try? Self.encoder.encode(s) else { continue }
            let url = file(for: s.start)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let h = try? FileHandle(forWritingTo: url) else { continue }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data + Data("\n".utf8))
            try? h.close()
        }
    }

    func day(_ d: Date) -> [Segment] {
        guard let text = try? String(contentsOf: file(for: d), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(Segment.self, from: Data($0.utf8)) }
    }

    private var current: URL { dir.appendingPathComponent("current.json") }

    func saveCurrent(_ s: Segment?) {
        guard let s, let data = try? Self.encoder.encode(s) else { try? FileManager.default.removeItem(at: current); return }
        try? data.write(to: current, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
    }

    /// Trecho que ficou aberto num crash: volta como fechado na hora da última gravação (e o arquivo some).
    func recoverCurrent() -> Segment? {
        defer { try? FileManager.default.removeItem(at: current) }
        guard let data = try? Data(contentsOf: current) else { return nil }
        return try? Self.decoder.decode(Segment.self, from: data)
    }

    func prune(now: Date) {
        guard let limit = calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: now)),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let keep = file(for: limit).lastPathComponent
        for f in files where f.pathExtension == "jsonl" && f.lastPathComponent < keep { try? FileManager.default.removeItem(at: f) }
    }
}
