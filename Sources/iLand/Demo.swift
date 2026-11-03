import Foundation

/// ILAND_DEMO=1: números e processos inventados no lugar dos reais, para os prints do README (scripts/readme_shots.sh).
/// Nada do Mac de quem roda aparece: temperatura, processos, uso do Claude, histórico, energia e rede são fictícios.
enum Demo {
    static let on = ProcessInfo.processInfo.environment["ILAND_DEMO"] != nil

    static func stats(_ real: SystemStats) -> SystemStats {
        var s = SystemStats()
        let now = Date()
        s.cpuTemp = 52; s.gpuTemp = 49
        var m = Metrics()
        m.cores = [38, 31, 24, 19, 12, 9, 7, 5, 4, 3]
        m.cpuTotal = 15
        m.memTotal = 16 << 30; m.memUsed = UInt64(10.4 * Double(1 << 30)); m.swapUsed = UInt64(0.6 * Double(1 << 30))
        m.netDown = 182_000; m.netUp = 24_000
        m.battery = 84; m.charging = false
        m.diskTotal = 494 << 30; m.diskFree = 212 << 30; m.diskUsedFraction = 0.57
        s.metrics = m
        s.processes = processes(now)
        s.usage = ClaudeUsage(updatedAt: now.timeIntervalSince1970,
                              fiveHour: .init(usedPercentage: 42, resetsAt: now.timeIntervalSince1970 + 7_200),
                              sevenDay: .init(usedPercentage: 63, resetsAt: now.timeIntervalSince1970 + 259_200))
        // Ruído fixo (mesmo print a cada execução): base calma com picos de vez em quando, como um dia normal.
        func noise(_ i: Int, _ k: Double) -> Double { let v = sin(Double(i) * k) * 43_758.5453; return v - v.rounded(.down) }
        var temp = 48.0
        s.history = (0..<300).map { i in
            let x = Double(i)
            let spike = noise(i, 7.13) > 0.94 ? 25 * noise(i, 3.7) : 0
            temp += (noise(i, 1.91) - 0.5) * 0.8 + (spike > 0 ? 1.5 : 0) - (temp - 50) * 0.04
            let burst = noise(i, 5.31) > 0.9 ? 900_000 * noise(i, 2.3) : 0
            return HistoryPoint(t: now.addingTimeInterval(2 * (x - 300)), cpu: 10 + 8 * noise(i, 12.9898) + spike,
                                temp: temp, down: 40_000 + 120_000 * noise(i, 4.1) + burst, up: 8_000 + 20_000 * noise(i, 6.7), mem: 63 + 2 * sin(x / 60) + noise(i, 9.3))
        }
        s.power = PowerReading(system: 9.8, battery: -9.8)
        s.energy = [AppEnergy(name: "Xcode", impact: 31.2), AppEnergy(name: "Safari", impact: 18.4), AppEnergy(name: "Figma", impact: 12.7),
                    AppEnergy(name: "Slack", impact: 6.3), AppEnergy(name: "Music", impact: 2.9)]
        s.netApps = [AppNet(name: "Safari", down: 120_000, up: 8_000), AppNet(name: "Slack", down: 41_000, up: 12_000)]
        s.ports = real.ports.map { _ in [] }
        return s
    }

    static let tunnels = [
        TunnelSpec(name: "Banco de staging", host: "deploy@bastion.example.com", port: nil, key: nil,
                   forwards: [.init(local: 5433, host: "db.staging.internal", port: 5432)]),
        TunnelSpec(name: "Redis + painel", host: "deploy@bastion.example.com", port: nil, key: nil,
                   forwards: [.init(local: 6380, host: "redis.internal", port: 6379), .init(local: 8081, host: "admin.internal", port: 80)]),
    ]

    private static func processes(_ now: Date) -> [ProcSample] {
        let me = getuid()
        let list: [(Int32, Int32, Double, Int, TimeInterval, String)] = [
            (501, 1, 24.3, 1_850_000, 14_400, "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            (502, 1, 11.8, 920_000, 86_400, "/Applications/Safari.app/Contents/MacOS/Safari"),
            (510, 1, 7.4, 640_000, 7_200, "/Applications/Figma.app/Contents/MacOS/Figma"),
            (530, 540, 6.1, 210_000, 1_800, "/opt/homebrew/bin/node"),
            (540, 1, 2.2, 95_000, 1_900, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            (520, 1, 3.5, 380_000, 172_800, "/Applications/Slack.app/Contents/MacOS/Slack"),
            (550, 1, 1.9, 120_000, 259_200, "/System/Applications/Music.app/Contents/MacOS/Music"),
            (560, 530, 1.2, 64_000, 1_700, "/opt/homebrew/bin/python3"),
            (570, 1, 0.8, 48_000, 345_600, "/System/Applications/Notes.app/Contents/MacOS/Notes"),
        ]
        return list.map { pid, ppid, cpu, rss, age, path in
            ProcSample(pid: pid, ppid: ppid, uid: me, cpu: cpu, rssKB: rss, elapsed: age, tty: "", path: path, startedAt: now.addingTimeInterval(-age))
        }
    }
}
