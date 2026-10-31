import Foundation

/// Saúde das máquinas Linux lida por SSH com comandos comuns do Linux (nada instalado nelas)
/// e as regras do iLand sobre ela. Lógica pura, sem AppKit: teste em test_machines.swift.
enum MachineLevel: Int, Comparable {
    case ok, warn, crit
    static func < (a: MachineLevel, b: MachineLevel) -> Bool { a.rawValue < b.rawValue }
}

struct MachineStatus: Equatable {
    struct Problem: Equatable { let level: MachineLevel; let text: String }
    var load1 = 0.0
    var cpus = 1
    var uptimeS = 0.0
    var memTotalKb = 0, memAvailKb = 0, swapTotalKb = 0, swapUsedKb = 0
    var diskPct = 0

    /// Uma chamada de SSH só, só leitura. Texto fixo (nada do usuário entra nele).
    static let remoteCommand = "cat /proc/loadavg; nproc; cat /proc/uptime; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo; df -P -k /"

    /// Lê a saída de `remoteCommand`. nil se faltar memória ou disco (saída cortada ou máquina estranha).
    static func parse(_ text: String) -> MachineStatus? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3 else { return nil }
        var s = MachineStatus()
        s.load1 = Double(lines[0].split(separator: " ").first ?? "") ?? 0
        s.cpus = max(Int(lines[1]) ?? 1, 1)
        s.uptimeS = Double(lines[2].split(separator: " ").first ?? "") ?? 0
        var mem: [String: Int] = [:]
        var disk: Int?
        for l in lines {
            let f = l.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 2, f[0].hasSuffix(":"), let v = Int(f[1]) { mem[String(f[0].dropLast())] = v }
            if l.hasPrefix("/"), let pct = f.first(where: { $0.hasSuffix("%") }), let p = Int(pct.dropLast()) { disk = p }
        }
        guard let total = mem["MemTotal"], let avail = mem["MemAvailable"], total > 0, let disk else { return nil }
        s.memTotalKb = total; s.memAvailKb = avail; s.diskPct = disk
        s.swapTotalKb = mem["SwapTotal"] ?? 0
        s.swapUsedKb = s.swapTotalKb - (mem["SwapFree"] ?? s.swapTotalKb)
        return s
    }

    var cpuPct: Int { Int(load1 / Double(cpus) * 100) }
    var ramPct: Int { memTotalKb > 0 ? 100 - memAvailKb * 100 / memTotalKb : 0 }
    var swapPct: Int { swapTotalKb > 0 ? swapUsedKb * 100 / swapTotalKb : 0 }

    /// Disco ≥80/≥90; RAM livre <15/<5; swap >50/>90. Vermelho primeiro.
    var problems: [Problem] {
        var p: [Problem] = []
        if diskPct >= 90 { p.append(.init(level: .crit, text: "disco \(diskPct)%")) }
        else if diskPct >= 80 { p.append(.init(level: .warn, text: "disco \(diskPct)%")) }
        let free = 100 - ramPct
        if free < 5 { p.append(.init(level: .crit, text: "RAM livre \(free)%")) }
        else if free < 15 { p.append(.init(level: .warn, text: "RAM livre \(free)%")) }
        if swapPct > 90 { p.append(.init(level: .crit, text: "swap \(swapPct)%")) }
        else if swapPct > 50 { p.append(.init(level: .warn, text: "swap \(swapPct)%")) }
        return p.sorted { $0.level > $1.level }
    }

    var level: MachineLevel { problems.first?.level ?? .ok }
}

enum MachineState: Equatable {
    case unknown
    case noContact(since: Date)   // o SSH falhou (IP fora do bastion, Mac sem rede): não conta como máquina caída
    case level(MachineLevel)

    /// Quanto pesa para os avisos e para a contagem ⚠ (sem contato não pesa).
    var alertLevel: MachineLevel {
        if case .level(let l) = self { return l }
        return .ok
    }
}

enum MachineRules {
    static let noContactNoticeAfter: TimeInterval = 30 * 60
    static let critRepeat: TimeInterval = 2 * 3600

    static func state(_ s: MachineStatus?, now: Date, previous: MachineState) -> MachineState {
        if let s { return .level(s.level) }
        if case .noContact(let since) = previous { return .noContact(since: since) }
        return .noContact(since: now)
    }

    /// Uma frase para a linha da página e para o aviso.
    static func headline(_ st: MachineState, _ s: MachineStatus?, now: Date) -> String {
        switch st {
        case .unknown: return "consultando…"
        case .noContact(let since): return "sem contato há \(Int(now.timeIntervalSince(since) / 60)) min"
        case .level(let l): return l == .ok ? "tudo certo" : (s?.problems.first?.text ?? "tudo certo")
        }
    }
}

/// Quando avisar: só quando o nível piora; vermelho repete a cada 2 h; sem contato avisa uma vez depois de 30 min
/// (devolve .warn) e não mexe no último nível conhecido.
struct MachineAlertGate {
    private var last: [String: MachineLevel] = [:]
    private var critAt: [String: Date] = [:]
    private var noContactNotified: Set<String> = []

    mutating func update(_ alias: String, _ st: MachineState, now: Date) -> MachineLevel? {
        if case .noContact(let since) = st {
            guard !noContactNotified.contains(alias), now.timeIntervalSince(since) >= MachineRules.noContactNoticeAfter else { return nil }
            noContactNotified.insert(alias)
            return .warn
        }
        noContactNotified.remove(alias)
        guard st != .unknown else { return nil }
        let lv = st.alertLevel, prev = last[alias] ?? .ok
        last[alias] = lv
        if lv == .crit {
            if prev < .crit || critAt[alias].map({ now.timeIntervalSince($0) >= MachineRules.critRepeat }) ?? true {
                critAt[alias] = now
                return .crit
            }
            return nil
        }
        critAt[alias] = nil
        return lv > prev ? lv : nil
    }
}

/// Uma linha JSON por consulta (7 dias), para gráfico e previsão de disco depois.
enum MachineHistory {
    static let keep: TimeInterval = 7 * 86400

    static func line(_ s: MachineStatus, now: Date) -> String {
        "{\"t\":\(Int(now.timeIntervalSince1970)),\"cpu\":\(s.cpuPct),\"ram\":\(s.ramPct),\"swap\":\(s.swapPct),\"disk\":\(s.diskPct)}"
    }

    static func prune(_ lines: [String], now: Date) -> [String] {
        lines.filter { l in
            guard let d = l.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["t"] as? Double else { return false }
            return now.timeIntervalSince1970 - t <= keep
        }
    }
}
