import Foundation

/// Guarda de processos: avisa quando a RAM vai acabar por causa de algo que cresce sem parar, e na última hora
/// encerra sozinho só processo de desenvolvimento que explica a falta. Spec:
/// docs/superpowers/specs/2026-11-06-guarda-de-processos-design.md. Lógica pura, relógio injetado:
/// teste em Tests/Unit/test_guard.swift.
struct GuardProc {
    let key: String        // "pid:início" (PID sozinho pode ser reutilizado)
    let pid: Int32
    let name: String
    let mb: Double         // memória total (phys_footprint), em MB
    let group: String      // marca de dono, ou o processo pai, ou o próprio processo
    let isDev: Bool        // pode ser encerrado sozinho (fora de app e fora da Apple)
    var owner: String? = nil   // CLAUDE_PROC_OWNER, se tiver
}

struct GuardItem: Identifiable, Equatable {
    enum Level { case warn, last }
    let group: String
    let name: String
    let pids: [Int32]
    let keys: [String]
    let mb: Double
    let rate: Double            // MB/s
    let minutesLeft: Double     // previsão para a folga acabar, somando tudo que cresce
    let level: Level
    let canAutoKill: Bool
    let countdown: Int?         // segundos até encerrar; nil = não vai encerrar sozinho
    let owner: String?
    var id: String { group }
}

struct ProcessGuard {
    static let point: TimeInterval = 30, window: TimeInterval = 600, minSpan: TimeInterval = 300, recent: TimeInterval = 120
    static let minGrowthMB = 500.0, minRate = 0.5, minR2 = 0.8, keepAboveMB = 300.0
    static let warnLeft: TimeInterval = 1200, lastLeft: TimeInterval = 120, pressureFor: TimeInterval = 30
    static let killRate = 5.0, killShare = 0.5, countdown: TimeInterval = 60, memberMinMB = 20.0

    private var hist: [String: [(t: Date, mb: Double)]] = [:]   // por grupo
    private var procHist: [String: [(t: Date, mb: Double)]] = [:]
    private var lastPoint: Date?
    private var critSince: Date?
    private var ignored: Set<String> = []         // chaves pid:início
    private var vetoed: [String: Date?] = [:]     // chave pid:início -> desde quando parou de crescer (nil = ainda cresce)
    private var countdownStart: [String: Date] = [:]

    /// Aviso calado para esses processos (pid:início). Não cala a última chance.
    mutating func ignore(_ keys: [String]) { ignored.formUnion(keys) }
    /// "Não encerrar" para esses processos: vale até cada um parar de crescer por 10 min.
    mutating func veto(_ keys: [String]) { keys.forEach { vetoed[$0] = .some(nil) }; countdownStart = [:] }

    /// Uma amostra. Devolve o que mostrar e as chaves (pid:início) a encerrar agora.
    mutating func update(_ procs: [GuardProc], headroomMB: Double, pressure: Int, now: Date) -> (items: [GuardItem], kill: [String]) {
        let groups = Dictionary(grouping: procs, by: \.group)
        if lastPoint.map({ now.timeIntervalSince($0) >= Self.point - 1 }) ?? true {
            lastPoint = now
            for (g, ps) in groups {
                let total = ps.map(\.mb).reduce(0, +)
                if total >= Self.keepAboveMB || hist[g] != nil { Self.push(&hist[g, default: []], (now, total), now) }
            }
            for p in procs { Self.push(&procHist[p.key, default: []], (now, p.mb), now) }
            hist = hist.filter { groups[$0.key] != nil }
            let live = Set(procs.map(\.key))
            procHist = procHist.filter { live.contains($0.key) }
        }
        critSince = pressure >= 4 ? (critSince ?? now) : nil

        var growing: [(g: String, rate: Double)] = []
        for (g, h) in hist {
            guard let r = Self.growth(h) else { continue }
            growing.append((g, r))
        }
        // "Não encerrar" acaba quando o processo para de crescer por 10 min (ou morre). "Ignorar" acaba quando ele morre.
        let live = Set(procs.map(\.key))
        for (k, since) in vetoed {
            if !live.contains(k) { vetoed[k] = nil }
            else if Self.netGrowth(procHist[k]) > Self.memberMinMB { vetoed[k] = .some(nil) }
            else if let s = since { if now.timeIntervalSince(s) >= Self.window { vetoed[k] = nil } }
            else { vetoed[k] = .some(now) }
        }
        ignored = ignored.intersection(live)

        let total = growing.map(\.rate).reduce(0, +)
        guard total > 0 else { countdownStart = [:]; return ([], []) }
        let left = headroomMB / total                       // segundos
        let crit = critSince.map { now.timeIntervalSince($0) >= Self.pressureFor } ?? false
        let last = left < Self.lastLeft || crit
        guard left < Self.warnLeft || last else { countdownStart = [:]; return ([], []) }

        let target = growing.max { $0.rate < $1.rate }!.g
        var items: [GuardItem] = [], kill: [String] = []
        for (g, rate) in growing.sorted(by: { $0.rate > $1.rate }) {
            let ps = (groups[g] ?? []).sorted { $0.mb > $1.mb }
            guard let top = ps.first else { continue }
            let isTarget = g == target && last
            if !isTarget && ps.allSatisfy({ ignored.contains($0.key) }) { continue }
            let members = ps.count == 1 ? ps : Self.culprits(ps, procHist, since: hist[g]?.first?.t, groupGrowth: Self.netGrowth(hist[g]))
            let auto = isTarget && !members.isEmpty && members.allSatisfy(\.isDev) && rate >= Self.killRate
                && rate / total >= Self.killShare && !members.contains { vetoed[$0.key] != nil }
            var cd: Int?
            if auto {
                let start = countdownStart[g] ?? now
                countdownStart[g] = start
                let remaining = Self.countdown - now.timeIntervalSince(start)
                if remaining <= 0 { kill += members.map(\.key); countdownStart[g] = nil } else { cd = Int(remaining.rounded(.up)) }
            }
            items.append(GuardItem(group: g, name: ps.count > 1 ? "\(top.name) (+\(ps.count - 1))" : top.name,
                                   pids: (auto ? members : ps).map(\.pid), keys: (auto ? members : ps).map(\.key),
                                   mb: ps.map(\.mb).reduce(0, +), rate: rate, minutesLeft: left / 60,
                                   level: isTarget ? .last : .warn, canAutoKill: auto, countdown: cd, owner: top.owner))
        }
        if !last { countdownStart = [:] } else { countdownStart = countdownStart.filter { $0.key == target } }
        return (items, kill)
    }

    private static func push(_ h: inout [(t: Date, mb: Double)], _ p: (Date, Double), _ now: Date) {
        h.append((t: p.0, mb: p.1))
        h.removeAll { now.timeIntervalSince($0.t) > window + point }
    }

    /// Ritmo (MB/s) se cresce sem parar; nil se não.
    static func growth(_ h: [(t: Date, mb: Double)]) -> Double? {
        guard let first = h.first, let lastP = h.last, lastP.t.timeIntervalSince(first.t) >= minSpan,
              lastP.mb - first.mb > minGrowthMB else { return nil }
        let (slope, r2) = fit(h)
        guard slope > minRate, r2 > minR2 else { return nil }
        let recentPts = h.filter { lastP.t.timeIntervalSince($0.t) <= recent + 1 }
        let recentSlope = recentPts.count >= 3 ? fit(recentPts).slope : 0
        return max(slope, recentSlope)
    }

    /// Os membros do grupo que explicam o crescimento: o menor conjunto que soma 90% do que o grupo cresceu.
    /// Assim um servidor estável no mesmo terminal do vazamento não é encerrado junto. Membro que entrou depois do
    /// começo do histórico do grupo conta inteiro (vazamento por processos novos). Se os culpados não explicam
    /// metade do crescimento do grupo, não há culpado claro: ninguém é encerrado sozinho.
    static func culprits(_ ps: [GuardProc], _ procHist: [String: [(t: Date, mb: Double)]], since: Date?, groupGrowth: Double) -> [GuardProc] {
        let grown = ps.compactMap { p -> (GuardProc, Double)? in
            guard let h = procHist[p.key], let f = h.first, let l = h.last else { return nil }
            let joinedLate = since.map { f.t.timeIntervalSince($0) > point } ?? false
            let g = joinedLate ? l.mb : l.mb - f.mb
            return g >= memberMinMB ? (p, g) : nil
        }.sorted { $0.1 > $1.1 }
        let total = grown.map(\.1).reduce(0, +)
        var acc = 0.0, out: [GuardProc] = []
        for (p, g) in grown where acc < total * 0.9 { out.append(p); acc += g }
        return acc >= groupGrowth * 0.5 ? out : []
    }

    static func netGrowth(_ h: [(t: Date, mb: Double)]?) -> Double {
        guard let h, let f = h.first, let l = h.last else { return 0 }
        return l.mb - f.mb
    }

    /// Mínimos quadrados: inclinação (MB/s) e R².
    static func fit(_ h: [(t: Date, mb: Double)]) -> (slope: Double, r2: Double) {
        let t0 = h[0].t
        let xs = h.map { $0.t.timeIntervalSince(t0) }, ys = h.map(\.mb)
        let n = Double(h.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my) }
        guard sxx > 0, syy > 0 else { return (0, 0) }
        return (sxy / sxx, sxy * sxy / (sxx * syy))
    }
}
