import Foundation

/// Regras de alerta do Mac. Lógica pura (sem AppKit), com relógio injetado: teste em test_alerts.swift.
/// Swap alto sozinho NÃO alerta (este Mac vive com ~20 GB de swap e 16 GB de RAM); quem manda é a pressão do kernel.
enum AlertKind: String, CaseIterable { case thermal, temperature, memory, disk, battery }

struct AlertInput {
    var cpuTemp = 0.0            // °C; 0 = sem leitura (não muda o estado)
    var pressure = 1             // kern.memorystatus_vm_pressure_level: 1 normal, 2 aviso, 4 crítica
    var swapUsed: UInt64 = 0     // só aparece no texto
    var memTotal: UInt64 = 0
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0
    var battery: Int?
    var charging = false
    var thermal = 0              // ProcessInfo.ThermalState.rawValue: 0 nominal, 1 fair, 2 serious, 3 critical
}

struct Alert: Identifiable, Equatable {
    let kind: AlertKind
    let critical: Bool
    let title: String
    let message: String
    var id: AlertKind { kind }
}

struct AlertEngine {
    static let tempOn = 90.0, tempOff = 85.0, tempFor: TimeInterval = 60
    static let memCriticalFor: TimeInterval = 60, memWarnFor: TimeInterval = 300
    static let diskMinFraction = 0.10, diskMinBytes: UInt64 = 15_000_000_000     // alerta: livre abaixo do MENOR dos dois (10% ou 15 GB): em disco grande, 10% seria cedo demais
    static let diskOffFraction = 0.12, diskOffBytes: UInt64 = 18_000_000_000     // sai: acima do menor dos dois (12% ou 18 GB)
    static let batteryLow = 20, batteryVeryLow = 10, batteryOff = 25
    static let cooldown: TimeInterval = 1800      // não repete a notificação do mesmo tipo em 30 min
    static let snoozeFor: TimeInterval = 3600     // "Ignorar 1h"

    /// Aviso de memória (pressão 2 por 5 min). Desligado: neste Mac o kernel fica em 2 o tempo todo (medido em 2026-10-03,
    /// com 39% de memória livre), então viraria um ▲ permanente. Pressão crítica (4) continua sempre ligada.
    var memWarnEnabled = false

    private var since: [String: Date] = [:]               // quando a condição começou ("temp", "memWarn", "memCrit")
    private var level: [AlertKind: Int] = [:]             // ativo: 1 aviso, 2 crítico
    private var notifiedLevel: [AlertKind: Int] = [:]     // maior nível já tratado neste episódio
    private var lastNotified: [AlertKind: Date] = [:]
    private var snoozedUntil: [AlertKind: Date] = [:]

    mutating func snooze(_ k: AlertKind, now: Date) { snoozedUntil[k] = now.addingTimeInterval(Self.snoozeFor) }

    /// Alertas ativos (fora os ignorados) e os que devem virar notificação agora.
    /// Notifica ao entrar no alerta (se passou o cooldown) e quando sobe de nível no mesmo episódio (ex.: bateria 20% -> 10%).
    mutating func update(_ s: AlertInput, now: Date) -> (active: [Alert], notify: [Alert]) {
        level[.thermal] = s.thermal >= 3 ? 2 : (s.thermal == 2 ? 1 : nil)
        level[.temperature] = temperature(s.cpuTemp, now, wasActive: level[.temperature] != nil)
        level[.memory] = memory(s.pressure, now, wasActive: level[.memory] != nil)
        level[.disk] = disk(s, wasActive: level[.disk] != nil)
        level[.battery] = battery(s, wasActive: level[.battery] != nil)
        snoozedUntil = snoozedUntil.filter { $0.value > now }

        var active: [Alert] = [], notify: [Alert] = []
        for k in AlertKind.allCases {
            guard let lv = level[k] else { notifiedLevel[k] = nil; continue }   // episódio acabou
            if snoozedUntil[k] != nil { continue }
            let a = Self.describe(k, lv, s)
            active.append(a)
            guard lv > (notifiedLevel[k] ?? 0) else { continue }
            let escalation = notifiedLevel[k] != nil
            if escalation || lastNotified[k].map({ now.timeIntervalSince($0) >= Self.cooldown }) ?? true {
                notify.append(a)
                lastNotified[k] = now
            }
            notifiedLevel[k] = lv
        }
        return (active, notify)
    }

    private mutating func temperature(_ t: Double, _ now: Date, wasActive: Bool) -> Int? {
        guard t > 0 else { return wasActive ? 1 : nil }   // sem leitura: mantém
        if wasActive {
            if t < Self.tempOff { since["temp"] = nil; return nil }
            return 1
        }
        guard t >= Self.tempOn else { since["temp"] = nil; return nil }
        let st = since["temp"] ?? now
        since["temp"] = st
        return now.timeIntervalSince(st) >= Self.tempFor ? 1 : nil
    }

    private mutating func memory(_ p: Int, _ now: Date, wasActive: Bool) -> Int? {
        func held(_ key: String, _ on: Bool, _ dur: TimeInterval) -> Bool {
            guard on else { since[key] = nil; return false }
            let st = since[key] ?? now
            since[key] = st
            return now.timeIntervalSince(st) >= dur
        }
        let crit = held("memCrit", p >= 4, Self.memCriticalFor)
        let warn = held("memWarn", p >= 2, Self.memWarnFor) && memWarnEnabled
        if p <= 1 { return nil }
        if crit { return 2 }
        return warn || wasActive ? 1 : nil
    }

    private func disk(_ s: AlertInput, wasActive: Bool) -> Int? {
        guard s.diskTotal > 0 else { return nil }
        func limit(_ fraction: Double, _ bytes: UInt64) -> UInt64 { min(UInt64(Double(s.diskTotal) * fraction), bytes) }
        if wasActive { return s.diskFree >= limit(Self.diskOffFraction, Self.diskOffBytes) ? nil : 1 }
        return s.diskFree < limit(Self.diskMinFraction, Self.diskMinBytes) ? 1 : nil
    }

    private func battery(_ s: AlertInput, wasActive: Bool) -> Int? {
        guard let b = s.battery, !s.charging else { return nil }
        if b <= Self.batteryVeryLow { return 2 }
        if b <= Self.batteryLow { return 1 }
        return wasActive && b < Self.batteryOff ? 1 : nil
    }

    static func describe(_ k: AlertKind, _ lv: Int, _ s: AlertInput) -> Alert {
        let gb = { (b: UInt64) in String(format: "%.0f", Double(b) / 1_000_000_000) }
        let (title, msg): (String, String) = switch k {
        case .thermal: ("Mac limitando o desempenho", lv == 2 ? "Muito quente. Feche o que não precisa agora." : "Está quente. Feche o que não precisa.")
        case .temperature: ("Mac esquentando: \(Int(s.cpuTemp)) °C", "Feche o que não precisa.")
        case .memory: lv == 2 ? ("Memória no limite", "Feche apps e abas parados (swap \(gb(s.swapUsed)) GB).")
                              : ("Memória apertada", "O Mac está comprimindo memória. Feche o que não precisa.")
        case .disk: ("Disco quase cheio: \(gb(s.diskFree)) GB livres", "Libere espaço para o Mac não travar.")
        case .battery: ("Bateria em \(s.battery ?? 0)%", lv == 2 ? "Ligue o carregador agora." : "Ligue o carregador.")
        }
        return Alert(kind: k, critical: lv == 2, title: title, message: msg)
    }
}
