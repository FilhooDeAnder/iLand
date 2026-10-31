// Uso: swiftc -parse-as-library Sources/iLand/ActivityLog.swift Sources/iLand/TimerRules.swift test_timer.swift -o /tmp/t_timer && /tmp/t_timer
// Fixture sintética: projetos e horários inventados para validar a troca de contexto.
import Foundation

@main struct TimerCheck {
    static func main() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: h, minute: m))! }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let text = try! String(contentsOfFile: "fixtures/activity-synthetic.jsonl", encoding: .utf8)
        let all = text.split(separator: "\n").map { try! dec.decode(Segment.self, from: Data($0.utf8)) }
        // O que o sensor tinha até o instante t (o trecho aberto vai até t).
        func seen(_ t: Date) -> [Segment] {
            all.filter { $0.start < t }.map { var s = $0; s.end = min(s.end, t); return s }
        }
        func firstFire(_ from: Date, _ to: Date, project: String) -> Date? {
            var t = from
            while t <= to {
                if TimerRules.mismatch(segments: seen(t), now: t, project: project) != nil { return t }
                t = t.addingTimeInterval(120)   // consulta a cada 2 min
            }
            return nil
        }
        // tarde: dispara entre 16:40 e 16:50
        guard let fire = firstFire(at(14, 40), at(20, 43), project: "/p/project-a") else { fatalError("não disparou à tarde") }
        assert(fire >= at(16, 40) && fire <= at(16, 50), "disparou às \(cal.dateComponents([.hour, .minute], from: fire))")
        let m = TimerRules.mismatch(segments: seen(fire), now: fire, project: "/p/project-a")!
        assert(m.project != "/p/project-a" && m.project.hasPrefix("/"), m.project)
        // manhã: timer certo (11:12–12:32), nenhum disparo
        assert(firstFire(at(11, 12), at(12, 32), project: "/p/project-a") == nil, "falso positivo de manhã")

        // "(?)", sem projeto e privados não contam
        func seg(_ a: Date, _ min: Double, _ p: String?, priv: Bool = false) -> Segment {
            Segment(start: a, end: a.addingTimeInterval(min * 60), app: "Cursor", title: nil, project: p, privateReason: priv ? "x" : nil)
        }
        let now = at(10, 20)
        assert(TimerRules.mismatch(segments: [seg(at(10, 0), 20, "api-demo (?)")], now: now, project: "/p/a") == nil)
        assert(TimerRules.mismatch(segments: [seg(at(10, 0), 20, nil)], now: now, project: "/p/a") == nil)
        assert(TimerRules.mismatch(segments: [seg(at(10, 0), 20, "/p/b", priv: true)], now: now, project: "/p/a") == nil)
        assert(TimerRules.mismatch(segments: [seg(at(10, 0), 9, "/p/b"), seg(at(10, 9), 2, "/p/a")], now: now, project: "/p/a") == nil, "voltou ao A")
        assert(TimerRules.mismatch(segments: [seg(at(10, 0), 9, "/p/b")], now: now, project: "/p/a")?.since == at(10, 0))

        // ausência: buraco de 30 min ou mais depois do início do timer, terminado há até 5 min
        let away = [seg(at(12, 0), 10, "/p/a"), seg(at(13, 15), 2, "/p/a")]
        let ab = TimerRules.absence(segments: away, entryStart: at(11, 50), now: at(13, 17))
        assert(ab?.from == at(12, 10) && ab?.to == at(13, 15), "\(String(describing: ab))")
        assert(TimerRules.absence(segments: away, entryStart: at(11, 50), now: at(13, 30)) == nil, "voltou há mais de 5 min")
        assert(TimerRules.absence(segments: away, entryStart: at(13, 0), now: at(13, 17)) == nil, "buraco antes do timer")

        // gate: uma vez; ignorado repete uma vez depois de 60 min; silêncio depois de resolvido
        var g = TimerGate()
        assert(g.shouldShow("e1|/p/b", now: at(16, 45)))
        assert(!g.shouldShow("e1|/p/b", now: at(17, 0)))
        assert(g.shouldShow("e1|/p/b", now: at(17, 45)), "repete uma vez")
        assert(!g.shouldShow("e1|/p/b", now: at(19, 0)), "só uma repetição")
        g.resolve("e2|/p/c")
        assert(!g.shouldShow("e2|/p/c", now: at(16, 45)))

        // links: "Está certo" faz B contar como a task por 30 dias; "não vigiar"
        var l = TimerLinks()
        l.taskProject["t1"] = "/p/project-a"
        l.allow(task: "t1", project: "/p/crm", now: at(16, 45))
        assert(l.counts(task: "t1", project: "/p/crm", now: at(18, 0)))
        assert(!l.counts(task: "t1", project: "/p/crm", now: at(16, 45).addingTimeInterval(31 * 86400)))
        l.ignored.insert("t2")
        assert(l.isIgnored("t2") && !l.isIgnored("t1"))
        let enc = try! JSONEncoder().encode(l)
        assert(try! JSONDecoder().decode(TimerLinks.self, from: enc) == l, "Codable")
        print("ok")
    }
}
