// Uso: swiftc -parse-as-library Sources/iLand/ProcessGuard.swift Tests/Unit/test_guard.swift -o /tmp/t_guard && /tmp/t_guard
import Foundation

@main struct GuardCheck {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func p(_ key: String, _ mb: Double, group: String? = nil, dev: Bool = true, name: String = "node") -> GuardProc {
            GuardProc(key: key, pid: Int32(key.split(separator: ":")[0])!, name: name, mb: mb, group: group ?? "g\(key)", isDev: dev)
        }
        /// Roda de 5 em 5 s até `until` e devolve o último resultado e quando o primeiro de cada nível apareceu.
        func run(_ g: inout ProcessGuard, from: TimeInterval = 0, until: TimeInterval, headroom: (TimeInterval) -> Double = { _ in 8000 }, pressure: (TimeInterval) -> Int = { _ in 1 },
                 procs: (TimeInterval) -> [GuardProc]) -> (last: [GuardItem], firstWarn: TimeInterval?, firstLast: TimeInterval?, killedAt: TimeInterval?, kill: [String]) {
            var fw: TimeInterval?, fl: TimeInterval?, ka: TimeInterval?, items: [GuardItem] = [], kill: [String] = []
            var t: TimeInterval = from
            while t <= until {
                let r = g.update(procs(t), headroomMB: headroom(t), pressure: pressure(t), now: t0.addingTimeInterval(t))
                items = r.items
                if fw == nil, r.items.contains(where: { $0.level == .warn || $0.level == .last }) { fw = t }
                if fl == nil, r.items.contains(where: { $0.level == .last }) { fl = t }
                if ka == nil, !r.kill.isEmpty { ka = t; kill = r.kill }
                t += 5
            }
            return (items, fw, fl, ka, kill)
        }

        // 1. Vazamento de 13 MB/s com a folga diminuindo junto: avisa, depois última chance, e encerra 60 s depois.
        var g = ProcessGuard()
        var r = run(&g, until: 1500, headroom: { 14000 - 13 * $0 }) { [p("100:1", 200 + 13 * $0)] }
        assert(r.firstWarn != nil && r.firstWarn! <= 330, "avisa logo que tem 5 min de dados: \(String(describing: r.firstWarn))")
        assert(r.firstLast != nil, "última chance")
        assert(r.killedAt != nil && r.killedAt! - r.firstLast! >= 60 && r.killedAt! - r.firstLast! <= 65, "encerra 60 s depois da última chance")
        assert(r.kill == ["100:1"])

        // 2. Vazamento que acelera: o ritmo dos últimos 2 min manda na previsão.
        g = ProcessGuard()
        let acel = run(&g, until: 400, headroom: { _ in 9000 }) { t in [p("101:1", 300 + 0.02 * t * t)] }
        assert(acel.last.first.map { $0.rate > 12 } ?? false, "ritmo recente (~16 MB/s), não a média: \(acel.last.first?.rate ?? 0)")

        // 3. Serrote do GC (sobe e cai) ainda conta como crescer sem parar.
        g = ProcessGuard()
        let serrote = run(&g, until: 700, headroom: { _ in 3000 }) { t in [p("102:1", 400 + 3 * t + (Int(t / 30) % 2 == 0 ? 0 : -60))] }
        assert(serrote.firstWarn != nil, "serrote avisa")

        // 4. Planning estável com 5 GB e Docker que sobe 4 GB em 2 min e para: nada.
        g = ProcessGuard()
        let estavel = run(&g, until: 1500, headroom: { _ in 1500 }) { t in
            [p("200:1", 5000 + Double(Int(t) % 60) - 30, name: "python"), p("201:1", min(4000, 300 + 30 * t), name: "com.apple.Virtualization")]
        }
        assert(estavel.firstWarn == nil, "estável não avisa, mesmo com pouca folga")

        // 5. 40 workers de 200 MB que crescem juntos viram um grupo.
        g = ProcessGuard()
        let workers = run(&g, until: 700, headroom: { _ in 4000 }) { t in
            (0..<40).map { i in p("\(300 + i):1", 150 + 0.1 * t, group: "o:sessao:agente") }
        }
        assert(workers.firstWarn != nil, "grupo avisa: \(workers.last)")
        assert(workers.last.first?.group == "o:sessao:agente")

        // 6. Ignorar cala o aviso, mas não a última chance.
        g = ProcessGuard()
        _ = run(&g, until: 400, headroom: { _ in 6000 }) { [p("400:1", 200 + 13 * $0)] }
        g.ignore(["400:1"])
        r = run(&g, from: 405, until: 430, headroom: { _ in 6000 }) { t in [p("400:1", 200 + 13 * t)] }
        assert(r.firstWarn == nil, "ignorado não avisa")
        r = run(&g, from: 435, until: 470, headroom: { _ in 900 }) { t in [p("400:1", 200 + 13 * t)] }
        assert(r.firstLast != nil, "última chance aparece mesmo ignorado")

        // 7. App nunca é encerrado sozinho.
        g = ProcessGuard()
        r = run(&g, until: 1500, headroom: { 14000 - 13 * $0 }) { [p("500:1", 200 + 13 * $0, dev: false, name: "Cursor Helper")] }
        assert(r.firstLast != nil && r.killedAt == nil, "app: última chance sem encerrar")
        assert(r.last.first?.canAutoKill == false)

        // 8. Alvo que responde por 20% do ritmo não é encerrado sozinho.
        g = ProcessGuard()
        r = run(&g, until: 1500, headroom: { 14000 - 30 * $0 }) { t in
            [p("600:1", 200 + 6 * t), p("601:1", 200 + 24 * t, dev: false, name: "Arc Helper")]
        }
        assert(r.killedAt == nil, "o dev (6 MB/s, 20%) não explica a falta")

        // 9. Não encerrar impede o encerramento.
        g = ProcessGuard()
        _ = run(&g, until: 900, headroom: { 14000 - 13 * $0 }) { [p("700:1", 200 + 13 * $0)] }
        g.veto(["700:1"])
        r = run(&g, from: 905, until: 1100, headroom: { _ in 500 }) { t in [p("700:1", 200 + 13 * t)] }
        assert(r.firstLast != nil && r.killedAt == nil, "vetado: sem encerrar")

        // 10. PID reutilizado (outro início) não herda o histórico.
        g = ProcessGuard()
        _ = run(&g, until: 400, headroom: { _ in 3000 }) { [p("800:1", 200 + 13 * $0)] }
        r = run(&g, from: 405, until: 470, headroom: { _ in 3000 }) { _ in [p("800:2", 6000)] }
        assert(r.firstWarn == nil, "processo novo no mesmo PID começa do zero")

        // 11. Pressão crítica por 30 s com algo crescendo é última chance, mesmo com folga calculada alta.
        g = ProcessGuard()
        r = run(&g, until: 500, headroom: { _ in 15000 }, pressure: { $0 > 400 ? 4 : 1 }) { [p("900:1", 200 + 13 * $0)] }
        assert(r.firstLast != nil && r.firstLast! >= 430, "pressão crítica 30 s")

        // 12. Vazamento no mesmo grupo de um servidor estável: só o vazamento é encerrado.
        g = ProcessGuard()
        r = run(&g, until: 1500, headroom: { 14000 - 13 * $0 }) { t in
            [p("1000:1", 200 + 13 * t, group: "p:zsh"), p("1001:1", 4000 + Double(Int(t) % 120), group: "p:zsh", name: "python")]
        }
        assert(r.kill == ["1000:1"], "só o que cresce: \(r.kill)")

        // 13. Vazamento por processos novos no grupo: o servidor estável que cresceu 30 MB não é o culpado.
        g = ProcessGuard()
        r = run(&g, until: 1500, headroom: { 14000 - 13 * $0 }) { t in
            let n = Int(t / 30)
            return [p("1100:1", 4000 + min(30, t / 10), group: "p:zsh", name: "python")] + (0..<n).map { i in p("\(1200 + i):1", 390, group: "p:zsh") }
        }
        assert(!r.kill.contains("1100:1"), "servidor estável não morre: \(r.kill)")

        print("test_guard ok")
    }
}
