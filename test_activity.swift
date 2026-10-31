// Uso: swiftc -parse-as-library Sources/iLand/ActivityLog.swift test_activity.swift -o /tmp/t_activity && /tmp/t_activity
import Foundation

@main struct ActivityCheck {
    static func main() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let t0 = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9))!
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        func smp(_ app: String, _ title: String? = nil, _ project: String? = nil, priv: String? = nil, input: TimeInterval) -> Sample {
            Sample(app: app, title: title, project: project, privateReason: priv, lastInput: at(input))
        }
        var t = ActivityTracker(calendar: cal)

        // troca de app fecha e abre
        assert(t.observe(smp("Cursor", "a.swift — iLand", "/p/iLand", input: 0), now: at(0)).isEmpty)
        assert(t.observe(smp("Cursor", "a.swift — iLand", "/p/iLand", input: 25), now: at(30)).isEmpty, "mesmo trecho")
        var c = t.observe(smp("Terminal", "zsh", "/p/iLand", input: 55), now: at(60))
        assert(c.count == 1 && c[0].app == "Cursor" && c[0].seconds == 60, "\(c)")
        // título muda = trecho novo
        c = t.observe(smp("Terminal", "vim", "/p/iLand", input: 85), now: at(90))
        assert(c.count == 1 && c[0].title == "zsh" && c[0].seconds == 30)

        // parado: fecha no último input, não na hora em que percebeu
        c = t.observe(smp("Terminal", "vim", "/p/iLand", input: 100), now: at(100 + 400))
        assert(c.count == 1 && c[0].end == at(100), "\(c)")
        assert(t.open == nil)
        // volta: abre de novo
        assert(t.observe(smp("Terminal", "vim", "/p/iLand", input: 600), now: at(600)).isEmpty && t.open != nil)

        // meia-noite corta
        let late = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 23, minute: 59))!
        var m = ActivityTracker(calendar: cal)
        _ = m.observe(Sample(app: "Cursor", title: "x", project: "/p", privateReason: nil, lastInput: late), now: late)
        let after = late.addingTimeInterval(120)
        c = m.observe(Sample(app: "Cursor", title: "x", project: "/p", privateReason: nil, lastInput: after), now: after)
        let midnight = cal.startOfDay(for: after)
        assert(c.count == 1 && c[0].end == midnight && m.open?.start == midnight, "\(c) \(String(describing: m.open))")

        // fechar (sono, bloqueio)
        c = m.close(at: after.addingTimeInterval(10))
        assert(c.count == 1 && m.open == nil)

        // soma por projeto, privado contado, herança de < 2 min entre trechos do mesmo projeto
        func seg(_ s: TimeInterval, _ e: TimeInterval, _ app: String, _ p: String?, priv: String? = nil) -> Segment {
            Segment(start: at(s), end: at(e), app: app, title: nil, project: p, privateReason: priv)
        }
        let day = [seg(0, 600, "Cursor", "/p/iLand"), seg(600, 660, "Chrome", nil, priv: "x"), seg(660, 1200, "Cursor", "/p/iLand"),
                   seg(1200, 1500, "Terminal", "/p/api-demo", priv: "digitação segura"), seg(1500, 1800, "Slack", nil),
                   seg(1800, 2000, "1Password", nil, priv: "app bloqueado")]
        let rows = ActivitySummary.byProject(day)
        assert(rows.first == .init(project: "/p/iLand", seconds: 1200, privateSeconds: 60), "\(rows)")
        assert(rows.contains(.init(project: "/p/api-demo", seconds: 300, privateSeconds: 300)))
        assert(rows.contains(.init(project: "Slack", seconds: 300, privateSeconds: 0)), "sem projeto = nome do app")
        assert(rows.contains(.init(project: "privado", seconds: 200, privateSeconds: 200)))
        // tela bloqueada (loginwindow) não conta como trabalho
        assert(!ActivitySummary.byProject([seg(0, 9000, "loginwindow", nil, priv: "digitação segura")]).contains { $0.project == "privado" })

        // arquivo: grava, lê, recupera crash, apaga > 30 dias
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iland-activity-test-\(UUID().uuidString)")
        let store = ActivityStore(dir: dir, calendar: cal)
        store.append([seg(0, 600, "Cursor", "/p/iLand"), seg(600, 600.4, "X", nil)])
        assert(store.day(t0) == [seg(0, 600, "Cursor", "/p/iLand")], "trecho < 1 s não grava")
        let perm = try! FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as! Int
        assert(perm == 0o700, "pasta 0700")
        store.saveCurrent(seg(700, 900, "Terminal", "/p/iLand"))
        assert(store.recoverCurrent() == seg(700, 900, "Terminal", "/p/iLand"))
        assert(store.recoverCurrent() == nil, "recupera uma vez só")
        let old = cal.date(byAdding: .day, value: -31, to: t0)!
        store.append([Segment(start: old, end: old.addingTimeInterval(60), app: "x", title: nil, project: nil, privateReason: nil)])
        store.prune(now: t0)
        assert(store.day(old).isEmpty && !store.day(t0).isEmpty)
        try? FileManager.default.removeItem(at: dir)
        print("ok")
    }
}
