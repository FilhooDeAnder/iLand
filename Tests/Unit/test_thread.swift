// Uso: swiftc -parse-as-library Sources/iLand/AgentThread.swift Tests/Unit/test_thread.swift -o /tmp/t_thread && /tmp/t_thread
import Foundation

@main struct ThreadCheck {
    static func main() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let t0 = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9))!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iland-thread-\(UUID().uuidString)")
        let store = ThreadStore(dir: dir, calendar: cal)

        // grava e lê o dia, em ordem; pasta 0700 e arquivo 0600
        let m1 = AgentMessage(role: .user, text: "como foi meu dia?", ts: t0)
        var m2 = AgentMessage(role: .assistant, text: "Foi bom.", ts: t0.addingTimeInterval(5))
        m2.chips = ["olhei seu dia"]
        let m3 = AgentMessage(role: .proactive, text: "Timer em X, você em Y.", ts: t0.addingTimeInterval(60),
                              actions: [AgentAction(id: "a1", title: "Parar às 16:15", kind: "timer_stop_at", arg: "16:15")])
        store.append(m1); store.append(m2); store.append(m3)
        let day = store.day(t0)
        assert(day.map(\.text) == ["como foi meu dia?", "Foi bom.", "Timer em X, você em Y."], "\(day.map(\.text))")
        assert(day[1].chips == ["olhei seu dia"] && day[2].actions.first?.arg == "16:15")
        let perm = { (p: String) in (try! FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as! Int) }
        assert(perm(dir.path) == 0o700 && perm(store.file(for: t0).path) == 0o600)

        // atualizar (estado da ação, texto final do streaming) regrava a mesma mensagem, não duplica
        var m3b = m3; m3b.state = "feito: parado às 16:15"
        store.update(m3b)
        let after = store.day(t0)
        assert(after.count == 3 && after[2].state == "feito: parado às 16:15")

        // limpeza: arquivos com mais de 30 dias somem
        let old = cal.date(byAdding: .day, value: -31, to: t0)!
        store.append(AgentMessage(role: .user, text: "velho", ts: old))
        store.prune(now: t0)
        assert(store.day(old).isEmpty && store.day(t0).count == 3)

        // chips legíveis para as ferramentas do cérebro
        assert(AgentChips.label(for: "mcp__iland__day_log", args: [:]) == "olhei seu dia")
        assert(AgentChips.label(for: "mcp__iland__project_info", args: ["project": "Project Demo"]) == "Project Demo")
        assert(AgentChips.label(for: "mcp__iland__timer_status", args: [:]) == "timer do ClickUp")
        assert(AgentChips.label(for: "mcp__iland__qualquer", args: [:]) == "qualquer")
        try? FileManager.default.removeItem(at: dir)
        print("ok")
    }
}
