import Foundation

/// Fila circular de tamanho fixo: depois de cheia, cada novo valor substitui o mais antigo. Nunca cresce além de `capacity`.
struct RingBuffer<T> {
    let capacity: Int
    private var storage: [T] = []
    private var head = 0   // índice do mais antigo quando cheia

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count }
    var last: T? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }
    /// Do mais antigo ao mais novo.
    var values: [T] { Array(storage[head...]) + Array(storage[..<head]) }

    mutating func append(_ x: T) {
        if storage.count < capacity { storage.append(x); return }
        storage[head] = x
        head = (head + 1) % capacity
    }
}

/// Uma amostra do histórico (aba Gráficos).
struct HistoryPoint {
    let t: Date
    let cpu: Double     // % total
    let temp: Double    // °C (0 = sem leitura)
    let down: Double    // bytes/s
    let up: Double
    let mem: Double     // % da RAM em uso
}

enum History {
    static let window: TimeInterval = 600   // últimos 10 min
    static let maxPoints = 300              // 10 min a 2 s; com o notch fechado (5 s) cobre 25 min, o gráfico mostra só 10
}

/// Apps que mais gastam energia, a partir de `top -l 2 -stats pid,power` (coluna POWER = "Energy Impact" do Monitor de Atividade).
struct AppEnergy: Equatable {
    let name: String
    let impact: Double
}

enum EnergyRank {
    /// A 1ª amostra do `top` não tem intervalo e sai zerada: vale o último bloco (cada bloco começa no cabeçalho "PID").
    static func parse(_ out: String) -> [Int32: Double] {
        var cur: [Int32: Double] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.first == "PID" { cur = [:]; continue }
            guard f.count >= 2, let pid = Int32(f[0]), let p = Double(f[1].replacingOccurrences(of: ",", with: ".")) else { continue }
            cur[pid] = p
        }
        return cur
    }

    /// Soma por app (Chrome Helper conta para "Google Chrome"); some com quem não gasta nada e com `exclude` (o próprio `top`).
    static func top(_ power: [Int32: Double], processes: [ProcSample], exclude: Int32 = -1, limit: Int = 5) -> [AppEnergy] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var sum: [String: Double] = [:]
        for (pid, p) in power where p > 0 && pid != exclude {
            let name = byPid[pid].map { $0.appName ?? $0.name } ?? "processo \(pid)"
            sum[name, default: 0] += p
        }
        return sum.map { AppEnergy(name: $0.key, impact: $0.value) }
            .sorted { $0.impact != $1.impact ? $0.impact > $1.impact : $0.name < $1.name }
            .prefix(limit).map { $0 }
    }
}
