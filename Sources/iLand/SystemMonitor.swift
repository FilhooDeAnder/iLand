import Foundation
import Combine

struct SystemStats {
    var cpuTemp = 0.0
    var gpuTemp = 0.0
    var metrics = Metrics()
    var processes: [ProcSample] = []   // ordenados por CPU
    var suspects: [Suspect] = []
    var thermalCritical = false
    var usage: ClaudeUsage?
    var alerts: [Alert] = []
    var history: [HistoryPoint] = []   // até History.maxPoints, do mais antigo ao mais novo
    var power: PowerReading?           // só com o painel aberto
    var energy: [AppEnergy]?           // só com a aba Gráficos visível; nil = medindo
    var ports: [PortRow]?              // só com a aba Portas visível; nil = procurando
    var netApps: [AppNet]?             // idem; nil = medindo
    var guardByPid: [Int32: GuardItem] = [:]   // guarda de processos: linha de RAM por PID (botões da SuspectRow)
    var leftovers: [Leftover] = []             // deixados por sessões do Claude que já fecharam
    var guardKills: [[String: Any]] = []       // últimos encerramentos automáticos (lidos do arquivo a cada 30 s)
}

/// Processo vivo de uma sessão do Claude que já fechou. O Anderson decide: Manter ou Encerrar.
struct Leftover: Identifiable {
    let key: String
    let sample: ProcSample
    let project: String
    let mb: Double
    var id: String { key }
}

class SystemMonitor: ObservableObject {
    @Published var stats: SystemStats?
    private var timer: Timer?
    private var interval: TimeInterval = 5
    private var busy = false  // main thread only: evita amostras sobrepostas
    // Tudo abaixo só é tocado dentro de `queue`.
    private let queue = DispatchQueue(label: "iland.monitor", qos: .utility)
    private let smcReader = SMCReader()
    private var cachedSensorPath: String?  // Cache sensor path to avoid repeated file system checks
    // A temperatura muda devagar: o programa sensors roda no máximo a cada 30 s. Cada rodada custa ~50 ms de CPU,
    // e a cada 5 s ele era metade do custo do iLand parado (achado pelo scripts/tortura.sh custo).
    private var sensorsCache: (at: Date, value: (cpu: Double?, gpu: Double?))?
    private let metricsSampler = MetricsSampler()
    private let usageFetcher = UsageFetcher()
    private var tracker = SuspectTracker()
    private var ignoredUntil: [Int32: Date] = [:]
    private var argsCache: [Int32: String] = [:]   // linha de comando por PID suspeito (evita um `ps` por ciclo)
    private var alertEngine = AlertEngine()
    private var history = RingBuffer<HistoryPoint>(capacity: History.maxPoints)
    private let energyTop = EnergyTop()
    private var panelOpen = false       // vista rápida ou visão geral aberta
    private var chartsVisible = false   // visão geral aberta na aba Gráficos: só aí roda o `top`
    private let portsWatch = PortsWatch()
    // Guarda de processos (só tocado em `queue`).
    private var processGuard = ProcessGuard()
    private var ownerByKey: [String: String] = [:]     // pid:início -> marca CLAUDE_PROC_OWNER (lido a cada 30 s)
    private var ownersAt: Date?
    private var deadSessions = Set<String>()
    private var guardNotified: [String: (at: Date, last: Bool)] = [:]   // grupo -> última notificação e se era última chance
    private var toldOwner = Set<String>()
    private var leftoverNotified = Set<String>()        // sessões mortas já avisadas
    private var guardKills: [[String: Any]] = []
    static let keptKey = "guardKept"                    // chaves pid:início que o Anderson mandou manter
    /// Última chance: a vista rápida abre sozinha.
    let guardUrgent = PassthroughSubject<Void, Never>()
    private var portsVisible = false    // visão geral aberta na aba Portas: só aí rodam `lsof` e `nettop`
    /// Depuração: ILAND_FAKE_ALERT=temp,memory,disk,battery,thermal injeta valores de alerta (não esquenta o Mac de verdade).
    private static let fakeAlerts = Set((Foundation.ProcessInfo.processInfo.environment["ILAND_FAKE_ALERT"] ?? "").split(separator: ",").map(String.init))

    init() {
        startMonitoring()
    }

    func ignore(pid: Int32, for interval: TimeInterval = 3600) {
        queue.async { self.ignoredUntil[pid] = Date().addingTimeInterval(interval) }
        stats?.suspects.removeAll { $0.sample.pid == pid }
    }

    func guardIgnore(_ item: GuardItem) {
        queue.async { self.processGuard.ignore(item.keys) }
        stats?.suspects.removeAll { item.pids.contains($0.sample.pid) && item.level == .warn }
    }

    func guardVeto(_ item: GuardItem) { queue.async { self.processGuard.veto(item.keys) } }

    /// Manter um processo deixado por sessão: sai da lista e não pergunta de novo (a guarda de RAM continua valendo).
    func keepLeftover(_ key: String) {
        var kept = UserDefaults.standard.stringArray(forKey: Self.keptKey) ?? []
        kept.append(key)
        UserDefaults.standard.set(Array(kept.suffix(200)), forKey: Self.keptKey)
        stats?.leftovers.removeAll { $0.key == key }
    }

    func snooze(_ kind: AlertKind) {
        queue.async { self.alertEngine.snooze(kind, now: Date()) }
        stats?.alerts.removeAll { $0.kind == kind }
    }

    /// Lê o disco de novo agora (botão Atualizar). Fora daqui, o disco só é lido na abertura do app.
    func refreshDisk() {
        queue.async { self.metricsSampler.refreshDisk() }
        updateStats()
    }

    func setChartsVisible(_ on: Bool) {
        queue.async { self.chartsVisible = on }
    }

    func setPortsVisible(_ on: Bool) {
        queue.async { self.portsVisible = on }
        if !on { portsWatch.stop() }
    }

    /// SIGTERM e, se ainda estiver vivo 3 s depois, SIGKILL. Antes de cada sinal confere se o PID ainda é o mesmo
    /// processo (caminho + hora de início): PIDs são reutilizados e não podemos matar outro por engano.
    func terminate(_ targets: [ProcTarget], grace: TimeInterval = 3) {
        for t in targets where Self.isSame(t) { kill(t.pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            for t in targets where Self.isSame(t) { kill(t.pid, SIGKILL) }
        }
        stats?.suspects.removeAll { s in targets.contains { $0.pid == s.sample.pid } }
    }

    private static func isSame(_ t: ProcTarget) -> Bool {
        guard let id = ProcessSampler.identity(pid: t.pid) else { return false }
        return t.matches(path: id.path, startedAt: id.startedAt)
    }

    func startMonitoring() {
        updateStats()
        schedule()
    }

    /// Painel aberto: 2 s. Fechado (só a temperatura na barra e a vigia de suspeitos): 5 s, bem mais barato.
    func setActive(_ on: Bool) {
        let new: TimeInterval = on ? 2 : 5
        guard new != interval else { return }
        interval = new
        queue.async { self.panelOpen = on }
        schedule()
        if on { updateStats() }
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.updateStats() }
        t.tolerance = interval * 0.3   // deixa o sistema juntar os despertares (energia)
        timer = t
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateStats() {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            // Wrap in autoreleasepool to release temporary objects immediately
            autoreleasepool {
                guard let self else { return }
                let stats = self.collect()
                DispatchQueue.main.async {
                    self.stats = Demo.on ? Demo.stats(stats) : stats
                    self.busy = false
                }
            }
        }
    }

    private func collect() -> SystemStats {
        let sensors: (cpu: Double?, gpu: Double?)
        if let c = sensorsCache, Date().timeIntervalSince(c.at) < 30 { sensors = c.value }
        else { sensors = readSensorsTemperature(); sensorsCache = (Date(), sensors) }
        var s = SystemStats()
        s.cpuTemp = getCPUTemperature(sensors)
        s.gpuTemp = getGPUTemperature(sensors)
        s.metrics = metricsSampler.sample()
        s.processes = ProcessSampler.sample()
        s.thermalCritical = Foundation.ProcessInfo.processInfo.thermalState == .critical
        switch Prefs.string(Prefs.Key.earsSource) {   // o que as orelhas mostram (Ajustes › Geral)
        case "codex": s.usage = ClaudeUsage.codex()
        case "none": s.usage = nil
        default:
            usageFetcher.poll()
            s.usage = ClaudeUsage.pick(api: usageFetcher.latest, file: ClaudeUsage.load())
        }

        let now = Date()
        let hot = tracker.update(s.processes, now: now)
        ignoredUntil = ignoredUntil.filter { $0.value > now }
        let byPid = Dictionary(s.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let me = getuid(), myPid = getpid()
        func suspect(_ p: ProcSample, hint: String? = nil) -> Suspect {
            let args = argsCache[p.pid] ?? ProcessSampler.args(pid: p.pid).trimmingCharacters(in: .whitespacesAndNewlines)
            argsCache[p.pid] = args
            var ancestors: [ProcSample] = []
            var cur = p
            while ancestors.count < 6, let parent = byPid[cur.ppid], parent.pid > 1 { ancestors.append(parent); cur = parent }
            return Suspect(sample: p, hint: hint ?? Origin.hint(for: p, ancestors: ancestors, args: args), chain: Origin.chain(ancestors), command: Redact.command(args), canKill: p.uid == me && !p.isProtected)
        }
        // Guarda de processos primeiro: quem enche a RAM vem antes dos suspeitos de CPU.
        let ram = runGuard(&s, now: now)
        let ramPids = Set(ram.compactMap(\.pids.first))
        s.suspects = ram.compactMap { it in it.pids.first.flatMap { byPid[$0] }.map { suspect($0, hint: GuardText.hint(it, owner: it.owner.map { ProcessFootprint.describe(owner: $0, dead: deadSessions) })) } }
            + s.processes
            .filter { hot.contains($0.pid) && ignoredUntil[$0.pid] == nil && $0.pid != myPid && $0.name != "kernel_task" && !ramPids.contains($0.pid) }
            .map { suspect($0) }
        argsCache = argsCache.filter { k, _ in s.suspects.contains { $0.sample.pid == k } }
        record(&s, now: now)
        return s
    }

    /// Notch fechado: só o histórico e as regras de alerta (barato). Potência só com o painel aberto; `top` só na aba Gráficos.
    private func record(_ s: inout SystemStats, now: Date) {
        let m = s.metrics
        if !m.cores.isEmpty {   // 1ª amostra de CPU não tem intervalo
            history.append(HistoryPoint(t: now, cpu: m.cpuTotal, temp: s.cpuTemp, down: m.netDown, up: m.netUp,
                                        mem: m.memTotal > 0 ? Double(m.memUsed) / Double(m.memTotal) * 100 : 0))
        }
        s.history = history.values

        var input = AlertInput(cpuTemp: s.cpuTemp, pressure: m.pressure, swapUsed: m.swapUsed, memTotal: m.memTotal,
                               diskFree: m.diskFree, diskTotal: m.diskTotal, battery: m.battery, charging: m.charging,
                               thermal: Foundation.ProcessInfo.processInfo.thermalState.rawValue)
        let fake = Self.fakeAlerts
        if fake.contains("temp") { input.cpuTemp = 93 }
        if fake.contains("memory") { input.pressure = 4 }
        if fake.contains("disk") { input.diskFree = 9_000_000_000 }
        if fake.contains("battery") { input.battery = 15; input.charging = false }
        if fake.contains("thermal") { input.thermal = 3 }
        let (active, notify) = alertEngine.update(input, now: now)
        s.alerts = active
        notify.forEach(Notifier.send)

        if panelOpen { s.power = PowerReader.read() }
        if chartsVisible {
            energyTop.pollIfDue(now: now)
            s.energy = energyTop.latest(now: now).map { EnergyRank.top($0.power, processes: s.processes, exclude: $0.topPid) }
        }
        if portsVisible {
            portsWatch.pollIfDue(now: now)
            let r = portsWatch.latest(now: now)
            s.ports = r.ports.map { PortScanner.rows($0.list, args: $0.args, processes: s.processes, me: getuid(), myPid: getpid()) }
            s.netApps = r.net.map { PortScanner.topApps($0.rates, names: $0.names, processes: s.processes) }
        }
    }

    private func getCPUTemperature(_ sensorsResult: (cpu: Double?, gpu: Double?)) -> Double {
        // Try sensors binary first for Apple Silicon (PMU tdie sensors)
        if let cpuTemp = sensorsResult.cpu, cpuTemp > 0 {
            return cpuTemp
        }
        
        // Try Apple Silicon specific SMC keys (M1/M2/M3)
        let appleSiliconKeys = [
            // M1 Performance cores
            "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
            // M1 Efficiency cores
            "Tp09", "Tp0T",
            // M2 Performance cores
            "Tp0f", "Tp0j",
            // M2 Efficiency cores
            "Tp1h", "Tp1t", "Tp1p", "Tp1l",
            // M3 Performance cores
            "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49",
            // M3 Efficiency cores
            "Te05", "Te0L", "Te0P", "Te0S"
        ]
        
        var temperatures: [Double] = []
        for key in appleSiliconKeys {
            if let temp = smcReader?.readTemperature(key: key), temp > 10, temp < 120 {
                temperatures.append(temp)
            }
        }
        
        // If we got Apple Silicon temps, return average
        if !temperatures.isEmpty {
            return temperatures.reduce(0, +) / Double(temperatures.count)
        }
        
        // Fallback to Intel SMC keys
        let intelKeys = ["TC0P", "TC0F", "TCAD", "TC0D", "TC0E", "TC0H", "Ts0P"]
        for key in intelKeys {
            if let temp = smcReader?.readTemperature(key: key), temp > 10, temp < 120 {
                return temp
            }
        }
        
        return 0
    }
    
    private func getGPUTemperature(_ sensorsResult: (cpu: Double?, gpu: Double?)) -> Double {
        // Try sensors binary first (GPU on Apple Silicon shares thermal zone with CPU)
        if let gpuTemp = sensorsResult.gpu, gpuTemp > 0 {
            return gpuTemp
        }
        
        // Try Apple Silicon GPU keys first (M1/M2/M3)
        let appleSiliconKeys = [
            // M1 GPU cores
            "Tg05", "Tg0D", "Tg0L", "Tg0T",
            // M2 GPU cores
            "Tg0f", "Tg0j"
        ]
        
        var temperatures: [Double] = []
        for key in appleSiliconKeys {
            if let temp = smcReader?.readTemperature(key: key), temp > 10, temp < 120 {
                temperatures.append(temp)
            }
        }
        
        // If we got Apple Silicon GPU temps, return average
        if !temperatures.isEmpty {
            return temperatures.reduce(0, +) / Double(temperatures.count)
        }
        
        // Fallback to Intel/AMD GPU keys
        let intelKeys = ["TGPU", "TG0D", "TG0P", "TGDD", "TG0F", "TG0T", "TCGC"]
        for key in intelKeys {
            if let temp = smcReader?.readTemperature(key: key), temp > 10, temp < 120 {
                return temp
            }
        }
        
        return 0
    }
    
    /// Recursos do bundle instalado ou Resources/sensors no checkout de desenvolvimento.
    private static func trustedSensorsPath() -> String? {
        SensorExecutable.find(executablePath: Bundle.main.executablePath ?? Foundation.ProcessInfo.processInfo.arguments[0],
                              resourcePath: Bundle.main.resourcePath)
    }

    private func readSensorsTemperature() -> (cpu: Double?, gpu: Double?) {
        guard let sensorPath = cachedSensorPath ?? Self.trustedSensorsPath() else { return (nil, nil) }
        cachedSensorPath = sensorPath
        
        let task = Process()
        task.launchPath = sensorPath
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        // Ensure pipes are closed after use
        defer {
            try? pipe.fileHandleForReading.close()
        }
        
        do {
            try task.run()
            
            // Read only the available data immediately (don't wait for EOF)
            // The sensors binary prints continuously, so we need to terminate it quickly
            Thread.sleep(forTimeInterval: 0.2)  // Give it 200ms to produce first output
            
            // Terminate immediately to prevent continuous output accumulation
            task.terminate()
            
            // Read only what's available (not waiting for EOF)
            let data = pipe.fileHandleForReading.availableData
            guard let output = String(data: data, encoding: .utf8) else { return (nil, nil) }
            
            let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard lines.count >= 2 else { return (nil, nil) }
            
            // First line contains sensor names
            let sensorNames = lines[0].components(separatedBy: ", ")
            
            // Find PMU tdie sensor indices (CPU temperature)
            var cpuTdieIndices: [Int] = []
            for (index, name) in sensorNames.enumerated() {
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                // Match "PMU tdie5", "PMU2 tdie6", etc.
                if trimmedName.range(of: "PMU2? tdie\\d+", options: .regularExpression) != nil {
                    cpuTdieIndices.append(index)
                }
            }
            
            // Parse temperature values from the last data line
            var cpuTemperatures: [Double] = []
            
            if lines.count >= 2 {
                let lastDataLine = lines[lines.count - 1].trimmingCharacters(in: .whitespaces)
                if !lastDataLine.isEmpty {
                    let values = lastDataLine.components(separatedBy: ", ")
                    
                    for index in cpuTdieIndices {
                        if index < values.count {
                            let valueStr = values[index].trimmingCharacters(in: .whitespaces)
                            if let temp = Double(valueStr), temp > 10, temp < 120 {
                                cpuTemperatures.append(temp)
                            }
                        }
                    }
                }
            }
            
            // Calculate CPU average
            let cpuAvg: Double? = cpuTemperatures.isEmpty ? nil : cpuTemperatures.reduce(0, +) / Double(cpuTemperatures.count)
            
            // GPU temperature is typically close to CPU on Apple Silicon (integrated)
            // Use CPU temp as a reasonable estimate for integrated GPU
            let gpuAvg: Double? = cpuAvg
            
            return (cpuAvg, gpuAvg)
            
        } catch {
            return (nil, nil)
        }
    }
}

// MARK: - Guarda de processos
extension SystemMonitor {
    /// Roda a guarda numa amostra: mede, decide, avisa, encerra o que tem de encerrar. Só em `queue`.
    fileprivate func runGuard(_ s: inout SystemStats, now: Date) -> [GuardItem] {
        // A cada 30 s: marcas de dono de todos os processos (um `ps`) e as sessões do Claude que morreram.
        if ownersAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            ownersAt = now
            deadSessions = ProcessFootprint.deadSessions()
            var byKey: [String: String] = [:]
            for (pid, o) in ProcessFootprint.allOwners() { if let st = ProcessFootprint.start(pid) { byKey["\(pid):\(st)"] = o } }
            ownerByKey = byKey
            let alive = Set(byKey.values.compactMap { $0.split(separator: ":").first.map(String.init) })
            deadSessions.subtracting(alive).forEach(ProcessFootprint.forgetSession)
            guardKills = ProcessFootprint.recentKills()
        }
        let me = getuid(), myPid = getpid()
        let kept = Set(UserDefaults.standard.stringArray(forKey: Self.keptKey) ?? [])
        var procs: [GuardProc] = [], samples: [String: ProcSample] = [:], leftovers: [Leftover] = []
        for p in s.processes where p.uid == me && p.pid != myPid {
            guard let st = ProcessFootprint.start(p.pid) else { continue }
            let key = "\(p.pid):\(st)"
            let owner = ownerByKey[key]
            let sid = owner?.split(separator: ":").first.map(String.init)
            let b = ProcessFootprint.bytes(p.pid) ?? 0
            if let owner, let sid, deadSessions.contains(sid), !kept.contains(key) {
                leftovers.append(Leftover(key: key, sample: p, project: owner.split(separator: ":", maxSplits: 2).dropFirst(2).first.map(String.init) ?? "",
                                          mb: Double(b) / 1_048_576))
            }
            guard b >= 50 << 20 else { continue }
            samples[key] = p
            // Grupo: a marca de dono (sessão:agente), senão o processo pai, senão o próprio processo.
            let group = owner.map { "o:" + $0.split(separator: ":").prefix(2).joined(separator: ":") } ?? (p.ppid > 1 ? "p:\(p.ppid)" : "s:\(key)")
            procs.append(GuardProc(key: key, pid: p.pid, name: p.appName.map { "\($0) (\(p.name))" } ?? p.name, mb: Double(b) / 1_048_576,
                                   group: group, isDev: ProcessFootprint.isDev(path: p.path, uid: p.uid), owner: owner))
        }
        s.leftovers = leftovers
        s.guardKills = guardKills
        for (sid, ls) in Dictionary(grouping: leftovers, by: { ownerByKey[$0.key]?.split(separator: ":").first.map(String.init) ?? "" })
            where !leftoverNotified.contains(sid) {
            leftoverNotified.insert(sid)
            let names = ls.map(\.sample.name).prefix(3).joined(separator: ", ")
            Notifier.send(title: "Sessão do Claude em \(ls[0].project) fechou e deixou \(ls.count == 1 ? names : "\(ls.count) processos")",
                          message: "\(names). Decida na página Serviços: Manter ou Encerrar.", id: "left-\(sid)")
        }
        let res = processGuard.update(procs, headroomMB: ProcessFootprint.headroomMB(swapUsed: s.metrics.swapUsed), pressure: s.metrics.pressure, now: now)
        res.items.forEach { notifyGuard($0, now: now) }
        s.guardByPid = Dictionary(res.items.compactMap { i in i.pids.first.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        guardNotified = guardNotified.filter { now.timeIntervalSince($0.value.at) < 600 }   // some e volta não notifica de novo em 10 min
        if !res.kill.isEmpty { killGuard(res.kill, samples: samples, items: res.items) }
        return res.items
    }

    private func notifyGuard(_ it: GuardItem, now: Date) {
        let urgent = it.level == .last
        let prev = guardNotified[it.group]
        let levelUp = urgent && prev?.last == false
        if let prev, !levelUp, !(urgent && now.timeIntervalSince(prev.at) >= 60) { return }
        guardNotified[it.group] = (now, urgent)
        Notifier.send(title: GuardText.title(it), message: GuardText.hint(it, owner: it.owner.map { ProcessFootprint.describe(owner: $0, dead: deadSessions) }), id: "guard-\(it.group)")
        if urgent { DispatchQueue.main.async { self.guardUrgent.send() } }
        if prev == nil, let o = it.owner, !toldOwner.contains(it.group) {
            toldOwner.insert(it.group)
            ProcessFootprint.tellOwner(o, String(format: "iLand: seu processo %@ (pid %d) cresce %.0f MB/s e a RAM do Mac acaba em ~%.0f min. Confira ou encerre.",
                                                 it.name, it.pids.first ?? 0, it.rate, max(1, it.minutesLeft)))
        }
    }

    private func killGuard(_ keys: [String], samples: [String: ProcSample], items: [GuardItem]) {
        let targets = keys.compactMap { samples[$0] }
        for k in keys {
            guard let p = samples[k], let it = items.first(where: { $0.keys.contains(k) }) else { continue }
            ProcessFootprint.logKill(["quando": Int(Date().timeIntervalSince1970), "pid": Int(p.pid), "nome": p.name, "caminho": p.path,
                                      "dono": it.owner ?? "", "mb": Int(it.mb), "ritmo_mb_s": Int(it.rate), "motivo": "RAM do Mac a menos de 2 min de acabar"])
            Notifier.send(title: "iLand encerrou \(p.name)", message: String(format: "Ele crescia %.0f MB/s e o Mac ia travar. Registro na página Serviços.", it.rate), id: "guard-kill-\(k)")
        }
        guardKills = ProcessFootprint.recentKills()
        DispatchQueue.main.async { self.terminate(targets.map(\.target), grace: 5) }
    }
}

/// Textos da guarda de processos.
enum GuardText {
    static func title(_ it: GuardItem) -> String {
        it.level == .last ? "RAM vai acabar agora: \(it.name)" : String(format: "RAM acaba em ~%.0f min", max(1, it.minutesLeft))
    }

    static func hint(_ it: GuardItem, owner: String?) -> String {
        var s = String(format: "RAM: %.1f GB, cresce %.0f MB/s", it.mb / 1024, it.rate)
        if let c = it.countdown { s += " · encerra em \(c) s" } else if it.level == .last && !it.canAutoKill { s += " · encerre você" }
        if let owner, !owner.isEmpty { s += " · \(owner)" }
        return s
    }
}
