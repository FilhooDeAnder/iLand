import Foundation

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

    func snooze(_ kind: AlertKind) {
        queue.async { self.alertEngine.snooze(kind, now: Date()) }
        stats?.alerts.removeAll { $0.kind == kind }
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
    func terminate(_ targets: [ProcTarget]) {
        for t in targets where Self.isSame(t) { kill(t.pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
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
        let sensors = readSensorsTemperature()
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
        s.suspects = s.processes
            .filter { hot.contains($0.pid) && ignoredUntil[$0.pid] == nil && $0.pid != myPid && $0.name != "kernel_task" }
            .map { p in
                let args = argsCache[p.pid] ?? ProcessSampler.args(pid: p.pid).trimmingCharacters(in: .whitespacesAndNewlines)
                argsCache[p.pid] = args
                var ancestors: [ProcSample] = []
                var cur = p
                while ancestors.count < 6, let parent = byPid[cur.ppid], parent.pid > 1 { ancestors.append(parent); cur = parent }
                return Suspect(sample: p, hint: Origin.hint(for: p, ancestors: ancestors, args: args), chain: Origin.chain(ancestors), command: Redact.command(args), canKill: p.uid == me && !p.isProtected)
            }
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
