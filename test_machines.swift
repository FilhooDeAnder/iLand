// Uso: swiftc -parse-as-library Sources/iLand/Machines.swift test_machines.swift -o /tmp/t_machines && /tmp/t_machines
// Saída sintética no formato dos comandos Linux.
import Foundation

@main struct MachinesCheck {
    static func main() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let sample = """
        0.00 0.00 0.00 1/100 1234
        2
        9417610.00 18835220.00
        MemTotal:         428644 kB
        MemAvailable:     201360 kB
        SwapTotal:       2525176 kB
        SwapFree:        2393564 kB
        Filesystem     1024-blocks    Used Available Capacity Mounted on
        /dev/nvme0n1p1     10000000 7000000   3000000      70% /
        """
        guard let s = MachineStatus.parse(sample) else { fatalError("não leu a amostra sintética") }
        assert(s.cpus == 2 && s.load1 == 0 && s.diskPct == 70 && s.ramPct == 54 && s.swapPct == 5, "\(s)")
        assert(Int(s.uptimeS / 86400) == 109)
        assert(s.problems.isEmpty && s.level == .ok)
        assert(MachineStatus.parse("") == nil && MachineStatus.parse("Permission denied\n\n") == nil)
        assert(MachineStatus.parse(sample.replacingOccurrences(of: "/dev/nvme0n1p1", with: "x")) == nil, "sem linha do disco")

        // limites
        func with(_ f: (inout MachineStatus) -> Void) -> MachineStatus { var x = s; f(&x); return x }
        assert(with { $0.diskPct = 80 }.problems == [.init(level: .warn, text: "disco 80%")])
        assert(with { $0.diskPct = 90 }.level == .crit)
        assert(with { $0.memAvailKb = 60_000 }.problems.first?.text == "RAM livre 13%")
        assert(with { $0.memAvailKb = 17_000 }.level == .crit)
        assert(with { $0.swapUsedKb = 1_300_000 }.problems.first?.text == "swap 51%")
        assert(with { $0.swapUsedKb = 2_300_000 }.level == .crit)
        let both = with { $0.diskPct = 85; $0.memAvailKb = 10_000 }
        assert(both.problems.first?.level == .crit && both.problems.count == 2, "vermelho primeiro")
        assert(with { $0.load1 = 1.0 }.cpuPct == 50)

        // estado
        assert(MachineRules.state(s, now: now, previous: .unknown) == .level(.ok))
        assert(MachineRules.state(nil, now: now, previous: .level(.ok)) == .noContact(since: now))
        let earlier = now.addingTimeInterval(-600)
        assert(MachineRules.state(nil, now: now, previous: .noContact(since: earlier)) == .noContact(since: earlier))
        assert(MachineState.noContact(since: now).alertLevel == .ok)

        // aviso: só quando piora; vermelho repete a cada 2 h
        var g = MachineAlertGate()
        assert(g.update("a", .level(.ok), now: now) == nil)
        assert(g.update("a", .level(.warn), now: now) == .warn)
        assert(g.update("a", .level(.warn), now: now.addingTimeInterval(300)) == nil, "não repete amarelo")
        assert(g.update("a", .level(.crit), now: now.addingTimeInterval(600)) == .crit)
        assert(g.update("a", .level(.crit), now: now.addingTimeInterval(600 + 7199)) == nil)
        assert(g.update("a", .level(.crit), now: now.addingTimeInterval(600 + 7200)) == .crit, "repete em 2 h")
        assert(g.update("a", .level(.warn), now: now.addingTimeInterval(9000)) == nil, "melhorou: sem aviso")
        // sem contato: não mexe no nível; um aviso só depois de 30 min
        var h = MachineAlertGate()
        _ = h.update("b", .level(.warn), now: now)
        assert(h.update("b", .noContact(since: now), now: now.addingTimeInterval(29 * 60)) == nil)
        assert(h.update("b", .noContact(since: now), now: now.addingTimeInterval(30 * 60)) == .warn)
        assert(h.update("b", .noContact(since: now), now: now.addingTimeInterval(90 * 60)) == nil, "uma vez só")
        assert(h.update("b", .level(.warn), now: now.addingTimeInterval(95 * 60)) == nil, "voltou igual: sem aviso")

        // título
        let warn = with { $0.diskPct = 82 }
        assert(MachineRules.headline(.level(.warn), warn, now: now) == "disco 82%")
        assert(MachineRules.headline(.level(.ok), s, now: now) == "tudo certo")
        assert(MachineRules.headline(.noContact(since: now.addingTimeInterval(-120)), nil, now: now) == "sem contato há 2 min")

        // histórico: 7 dias
        let l = MachineHistory.line(s, now: now)
        assert(l.contains("\"disk\":70") && !l.contains("\n"))
        let lines = [MachineHistory.line(s, now: now.addingTimeInterval(-8 * 86400)), l, "lixo"]
        assert(MachineHistory.prune(lines, now: now) == [l])
        print("ok")
    }
}
