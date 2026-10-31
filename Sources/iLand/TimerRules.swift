import Foundation

/// Vigia do timer do ClickUp (cérebro, fase 1): regras puras, zero token. Teste em test_timer.swift,
/// validado com cenários sintéticos de troca de projeto.
enum TimerRules {
    static let window: TimeInterval = 20 * 60
    static let otherMin: TimeInterval = 8 * 60      // ≥ 8 min em outros projetos na janela…
    static let ownMax: TimeInterval = 60            // …e < 1 min no projeto do timer
    static let awayMin: TimeInterval = 30 * 60
    static let awayFresh: TimeInterval = 5 * 60

    struct Mismatch: Equatable { let project: String; let since: Date }

    /// Só conta trecho com projeto por caminho ("/…"): "x (?)", sem projeto, privado e idle não contam nem quebram a janela.
    static func mismatch(segments: [Segment], now: Date, project a: String) -> Mismatch? {
        let from = now.addingTimeInterval(-window)
        var own: TimeInterval = 0, other: [String: TimeInterval] = [:], first: [String: Date] = [:]
        for s in segments where s.privateReason == nil {
            guard let p = s.project, p.hasPrefix("/") else { continue }
            let st = max(s.start, from), en = min(s.end, now)
            guard en > st else { continue }
            if p == a { own += en.timeIntervalSince(st) } else {
                other[p, default: 0] += en.timeIntervalSince(st)
                first[p] = min(first[p] ?? st, st)
            }
        }
        let total = other.values.reduce(0, +)
        guard total >= otherMin, own < ownMax, let b = other.max(by: { $0.value < $1.value })?.key else { return nil }
        return Mismatch(project: b, since: first[b] ?? from)
    }

    /// Buraco sem atividade (tela bloqueada, idle) ≥ 30 min depois do início do timer, que terminou há ≤ 5 min.
    static func absence(segments: [Segment], entryStart: Date, now: Date) -> (from: Date, to: Date)? {
        let segs = segments.filter { $0.end > entryStart }.sorted { $0.start < $1.start }
        var last = entryStart, best: (Date, Date)?
        for s in segs {
            let gapFrom = max(last, entryStart)
            if s.start.timeIntervalSince(gapFrom) >= awayMin, now.timeIntervalSince(s.start) <= awayFresh { best = (gapFrom, s.start) }
            last = max(last, s.end)
        }
        return best.map { (from: $0.0, to: $0.1) }
    }
}

/// Um cartão por chave; ignorado repete uma vez depois de 60 min; resolvido = silêncio.
struct TimerGate {
    static let repeatAfter: TimeInterval = 3600
    private var shown: [String: (first: Date, repeated: Bool)] = [:]
    private var resolved: Set<String> = []

    mutating func shouldShow(_ key: String, now: Date) -> Bool {
        if resolved.contains(key) { return false }
        guard let s = shown[key] else { shown[key] = (now, false); return true }
        if !s.repeated, now.timeIntervalSince(s.first) >= Self.repeatAfter { shown[key] = (s.first, true); return true }
        return false
    }

    mutating func resolve(_ key: String) { resolved.insert(key) }
}

/// Task do ClickUp -> projeto, tasks que não se vigiam e projetos que também contam ("Está certo", 30 dias).
struct TimerLinks: Codable, Equatable {
    static let allowFor: TimeInterval = 30 * 86400
    var taskProject: [String: String] = [:]
    var ignored: Set<String> = []
    var alsoCounts: [String: [String: Date]] = [:]

    mutating func allow(task: String, project: String, now: Date) { alsoCounts[task, default: [:]][project] = now.addingTimeInterval(Self.allowFor) }
    func counts(task: String, project: String, now: Date) -> Bool { (alsoCounts[task]?[project]).map { $0 > now } ?? false }
    func isIgnored(_ task: String) -> Bool { ignored.contains(task) }
}
