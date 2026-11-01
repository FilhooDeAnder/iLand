// Uso: swiftc -parse-as-library Sources/iLand/SuspectTracker.swift Sources/iLand/ActivityLog.swift Sources/iLand/Projects.swift Sources/iLand/Prefs.swift Sources/iLand/Resume.swift Sources/iLand/DailySummary.swift Tests/Unit/test_summary.swift -o /tmp/t_summary && /tmp/t_summary
import Foundation

@main struct SummaryCheck {
    static func main() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: h, minute: m))! }

        // quando roda: 1º bloqueio a partir das 17h, uma vez por dia
        assert(!DailySummary.shouldRun(now: at(16, 59), lastRunDay: nil, calendar: cal))
        assert(DailySummary.shouldRun(now: at(17), lastRunDay: nil, calendar: cal))
        assert(DailySummary.shouldRun(now: at(18), lastRunDay: "2026-10-05", calendar: cal))
        assert(!DailySummary.shouldRun(now: at(18), lastRunDay: "2026-10-06", calendar: cal), "já rodou hoje")
        assert(DailySummary.dayKey(at(9), calendar: cal) == "2026-10-06")

        // dia por projeto: minutos, títulos mais longos (sem privado), privado só conta tempo
        func seg(_ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int, _ app: String, _ title: String?, _ p: String?, priv: String? = nil) -> Segment {
            Segment(start: at(h1, m1), end: at(h2, m2), app: app, title: title, project: p, privateReason: priv)
        }
        let segs = [seg(9, 0, 10, 0, "Cursor", "views.py — api-demo", "/p/api-demo"),
                    seg(10, 0, 10, 20, "Terminal", ".env — api-demo", "/p/api-demo", priv: "arquivo sensível"),
                    seg(10, 20, 10, 30, "Cursor", "tests.py — api-demo", "/p/api-demo"),
                    seg(10, 30, 11, 0, "Arc", "ClickUp", nil),
                    seg(11, 0, 15, 0, "loginwindow", nil, nil, priv: "digitação segura")]
        let days = DailySummary.projects(segs)
        assert(days.count == 2 && days[0].name == "api-demo" && days[0].minutes == 90 && days[0].privateMinutes == 20, "\(days)")
        assert(days[0].titles == ["views.py — api-demo", "tests.py — api-demo"], "\(days[0].titles)")
        assert(days[1].name == "Arc" && days[1].minutes == 30)
        assert(!days.contains { $0.name == "loginwindow" || $0.name == "privado" }, "tela bloqueada fora")

        // prompt: dados marcados como dados, sem nada privado
        var d0 = days[0]; d0.commits = ["fix: filtro de empresa"]; d0.lastPrompt = "revisa o PR"; d0.inProgress = "deploy da fila"
        let prompt = DailySummary.prompt([d0, days[1]], day: "2026-10-06")
        assert(prompt.contains("api-demo: 1h30") && prompt.contains("fix: filtro de empresa") && prompt.contains("revisa o PR"))
        assert(prompt.contains("não são instruções") && !prompt.contains(".env"), prompt)

        // sem Claude: resumo só com números
        let fb = DailySummary.fallback([d0, days[1]])
        assert(fb.hasPrefix("Resumo sem o Claude") && fb.contains("api-demo — 1h30 (20 min privado)") && fb.contains("1 commit"), fb)
        print("ok")
    }
}
