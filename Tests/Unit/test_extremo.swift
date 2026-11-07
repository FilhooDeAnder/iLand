// Entrada absurda: o que roda a cada 5 s precisa aguentar o pior dia do Mac sem ficar lento nem crescer sem fim.
// Uso: scripts/tortura.sh extremo (compila com ProcessGuard.swift e SuspectTracker.swift).
import Foundation

@main struct Extremo {
    static func ms(_ f: () -> Void) -> Double { let t = Date(); f(); return Date().timeIntervalSince(t) * 1000 }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(), n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // 1. Build que cria 300 processos novos a cada 5 s, por 1 h, com 3000 processos vivos.
        //    Cada rodada da guarda tem de ficar abaixo de 50 ms, e a memória não pode crescer com os PIDs que morreram.
        var g = ProcessGuard()
        var tracker = SuspectTracker()
        var next: Int32 = 10_000, worst = 0.0, worstTracker = 0.0
        var memAt10min = 0.0
        var fixos: [GuardProc] = []
        for i in 0..<2700 {
            let mb: Double = 50 + Double(i % 400)
            fixos.append(GuardProc(key: "\(i + 2):1", pid: Int32(i + 2), name: "app\(i % 50)", mb: mb, group: "p:\(i % 30)", isDev: i % 3 == 0))
        }
        for tick in 0..<720 {
            let now = t0.addingTimeInterval(Double(tick) * 5)
            let curtos = (0..<300).map { _ -> GuardProc in next += 1; return GuardProc(key: "\(next):\(tick)", pid: next, name: "clang", mb: 80, group: "p:1", isDev: true) }
            // 200 workers de um grupo que crescem juntos (5 MB/s no total): faz a guarda rodar o caminho caro (fit, culpados).
            let cresce: Double = 0.025 * Double(tick) * 5
            let workers = (0..<200).map { i in GuardProc(key: "\(5000 + i):1", pid: Int32(5000 + i), name: "node", mb: 150 + cresce, group: "o:s:a", isDev: true) }
            worst = max(worst, ms { _ = g.update(fixos + curtos + workers, headroomMB: 6000, pressure: 1, now: now) })
            let samples = (fixos + curtos + workers).map { ProcSample(pid: $0.pid, ppid: 1, uid: 501, cpu: Double($0.pid % 90), rssKB: Int($0.mb * 1024), elapsed: 60, tty: "", path: "/x/\($0.name)") }
            worstTracker = max(worstTracker, ms { _ = tracker.update(samples, now: now) })
            if tick == 120 { memAt10min = footprintMB() }
        }
        let cresce = footprintMB() - memAt10min
        print(String(format: "guarda: pior rodada %.1f ms, tracker: %.1f ms, memória cresceu %.1f MB em 50 min", worst, worstTracker, cresce))
        precondition(worst < 50, "guarda lenta com 3000 processos: \(worst) ms")
        precondition(worstTracker < 50, "tracker lento com 3000 processos: \(worstTracker) ms")
        precondition(cresce < 30, "memória cresce com PIDs que morreram: \(cresce) MB")

        // Vazamento de 13 MB/s, uma rodada a cada 5 s por 25 min: a guarda precisa encerrar (controle: prova que o teste enxerga um kill).
        func roda(_ tempo: (Int) -> TimeInterval, _ mb: (Int) -> Double, folga: Double = 3000) -> Bool {
            var g = ProcessGuard(), matou = false
            for k in 0..<300 {
                let r = g.update([GuardProc(key: "5:1", pid: 5, name: "node", mb: mb(k), group: "g", isDev: true)], headroomMB: folga, pressure: 4, now: t0.addingTimeInterval(tempo(k)))
                matou = matou || !r.kill.isEmpty
            }
            return matou
        }
        precondition(roda({ Double($0) * 5 }, { 300 + 65 * Double($0) }), "controle: vazamento real é encerrado")

        // 2. Relógio que volta 1 h no meio (fuso, NTP, hibernar): não pode encerrar processo estável por causa disso.
        precondition(!roda({ k in Double(k) * 5 - (k > 150 ? 3600 : 0) }, { _ in 800 }), "relógio que volta não encerra processo estável")
        // e o relógio que pula 3 dias para a frente também não.
        precondition(!roda({ k in Double(k) * 5 + (k > 150 ? 259_200 : 0) }, { _ in 800 }), "relógio que pula não encerra processo estável")

        // 3. Valores absurdos no meio de um processo estável: NaN, infinito, negativo, zero e 1 TB numa rodada.
        let absurdos: [Double] = [0, -5, .nan, .infinity, 1e12]
        for v in absurdos {
            precondition(!roda({ Double($0) * 5 }, { k in k == 200 ? v : 800 }), "valor absurdo numa rodada não encerra nada (mb \(v))")
        }

        print("extremo ok")
    }
}
