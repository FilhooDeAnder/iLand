// Uso: swiftc -parse-as-library Sources/iLand/Prefs.swift test_prefs.swift -o /tmp/t_prefs && /tmp/t_prefs
import Foundation

@main struct PrefsTests {
    static func main() {
        // Páginas escondidas: texto -> conjunto, ignora lixo e o Resumo (0).
        assert(Prefs.hiddenPages("") == [])
        assert(Prefs.hiddenPages("2,5") == [2, 5])
        assert(Prefs.hiddenPages(" 3 , x, 0, -1, 7") == [3, 7])
        assert(Prefs.csv([5, 2]) == "2,5")
        assert(Prefs.hiddenPages(Prefs.csv([1, 4, 8])) == [1, 4, 8])

        // Ordem das páginas (9 páginas, 0 = Resumo sempre primeiro).
        assert(Prefs.order("", count: 9) == [0, 1, 2, 3, 4, 5, 6, 7, 8])
        assert(Prefs.order("0,5,3", count: 9) == [0, 5, 3, 1, 2, 4, 6, 7, 8])
        assert(Prefs.order("3,0,3,x,99,-1,2", count: 9) == [0, 3, 2, 1, 4, 5, 6, 7, 8])   // repetido, lixo e fora da faixa saem; Resumo volta ao topo
        assert(Prefs.order(Prefs.orderCSV([0, 8, 7]), count: 9).prefix(3) == [0, 8, 7])

        // Modelo do Claude: só valores conhecidos chegam à linha de comando.
        let d = UserDefaults.standard
        let old = d.object(forKey: Prefs.Key.claudeModel)
        d.set("--dangerously-skip-permissions", forKey: Prefs.Key.claudeModel)
        assert(Prefs.claudeModel == "haiku")
        d.set("sonnet", forKey: Prefs.Key.claudeModel)
        assert(Prefs.claudeModel == "sonnet")
        if let old { d.set(old, forKey: Prefs.Key.claudeModel) } else { d.removeObject(forKey: Prefs.Key.claudeModel) }

        // Tempo de recolher fica entre 0,3 e 10 s, mesmo com valor absurdo.
        let oldDelay = d.object(forKey: Prefs.Key.quickHideDelay)
        d.set(9999.0, forKey: Prefs.Key.quickHideDelay); assert(Prefs.quickHideDelay == 10)
        d.set(-5.0, forKey: Prefs.Key.quickHideDelay); assert(Prefs.quickHideDelay == 0.3)
        if let oldDelay { d.set(oldDelay, forKey: Prefs.Key.quickHideDelay) } else { d.removeObject(forKey: Prefs.Key.quickHideDelay) }
        UserDefaults.standard.set("worker-demo, web-demo,;rm -rf,apidocs,worker-demo", forKey: Prefs.Key.machines)
        assert(Prefs.machines == ["worker-demo", "web-demo", "apidocs"], "só apelidos válidos, sem repetir")
        UserDefaults.standard.removeObject(forKey: Prefs.Key.machines)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        func h(_ hour: Int, _ min: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour, minute: min))! }
        assert(!Prefs.assistantActive(h(6, 59), calendar: cal, from: 7, to: 19))
        assert(Prefs.assistantActive(h(7), calendar: cal, from: 7, to: 19))
        assert(Prefs.assistantActive(h(18, 59), calendar: cal, from: 7, to: 19))
        assert(!Prefs.assistantActive(h(19), calendar: cal, from: 7, to: 19))
        assert(Prefs.assistantActive(h(23), calendar: cal, from: 22, to: 6) && !Prefs.assistantActive(h(12), calendar: cal, from: 22, to: 6), "atravessa a meia-noite")
        print("ok")
    }
}
