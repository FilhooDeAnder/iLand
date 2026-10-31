// Uso: swiftc -parse-as-library Sources/iLand/AlertEngine.swift test_alerts.swift -o /tmp/t_alerts && /tmp/t_alerts
import Foundation

@main struct AlertsCheck {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        func kinds(_ a: [Alert]) -> [AlertKind] { a.map(\.kind) }
        let ok = AlertInput(cpuTemp: 60, pressure: 1, swapUsed: 20_000_000_000, memTotal: 16_000_000_000,
                            diskFree: 74_000_000_000, diskTotal: 494_000_000_000, battery: 80, charging: false, thermal: 0)

        // Normal (inclusive 20 GB de swap com 16 GB de RAM): nada.
        var e = AlertEngine()
        assert(e.update(ok, now: t0).active.isEmpty, "swap alto sozinho não alerta")

        // Temperatura: só depois de 60 s seguidos >= 90; sai abaixo de 85 (histerese).
        var hot = ok; hot.cpuTemp = 93
        assert(e.update(hot, now: at(10)).active.isEmpty, "acabou de esquentar")
        assert(e.update(hot, now: at(69)).active.isEmpty, "59 s")
        var r = e.update(hot, now: at(70))
        assert(kinds(r.active) == [.temperature] && kinds(r.notify) == [.temperature], "60 s seguidos: alerta + notificação")
        assert(r.active[0].title == "Mac esquentando: 93 °C")
        assert(e.update(hot, now: at(72)).notify.isEmpty, "não repete a notificação")
        var warm = ok; warm.cpuTemp = 87
        assert(kinds(e.update(warm, now: at(80)).active) == [.temperature], "87 °C: ainda ativo (histerese)")
        var noRead = ok; noRead.cpuTemp = 0
        assert(kinds(e.update(noRead, now: at(82)).active) == [.temperature], "sem leitura: mantém")
        assert(e.update(ok, now: at(90)).active.isEmpty, "abaixo de 85: sai")
        // Volta a esquentar dentro do cooldown: alerta aparece, mas sem nova notificação.
        _ = e.update(hot, now: at(100))
        r = e.update(hot, now: at(161))
        assert(kinds(r.active) == [.temperature] && r.notify.isEmpty, "cooldown de 30 min segura a notificação")
        _ = e.update(ok, now: at(170))
        _ = e.update(hot, now: at(2000))
        assert(kinds(e.update(hot, now: at(2061)).notify) == [.temperature], "passou o cooldown: notifica de novo")

        // Pico curto não conta: precisa ser seguido.
        var e2 = AlertEngine()
        _ = e2.update(hot, now: at(0)); _ = e2.update(warm, now: at(30))
        assert(e2.update(hot, now: at(61)).active.isEmpty, "caiu no meio: recomeça a contagem")

        // Ignorar 1h: some da lista e não notifica; volta depois de 1 h se continuar.
        e2.snooze(.temperature, now: at(61))
        _ = e2.update(hot, now: at(100))
        r = e2.update(hot, now: at(200))
        assert(r.active.isEmpty && r.notify.isEmpty, "ignorado")
        assert(kinds(e2.update(hot, now: at(61 + 3601)).active) == [.temperature], "depois de 1 h volta")

        // Memória: crítica (4) por 60 s; aviso (2) por 5 min; sai só no normal (1).
        var m = AlertEngine()
        var p4 = ok; p4.pressure = 4
        var p2 = ok; p2.pressure = 2
        _ = m.update(p4, now: at(0))
        assert(m.update(p4, now: at(59)).active.isEmpty)
        r = m.update(p4, now: at(60))
        assert(kinds(r.notify) == [.memory] && r.active[0].critical, "crítica 60 s")
        assert(r.active[0].message.contains("swap 20 GB"))
        assert(kinds(m.update(p2, now: at(70)).active) == [.memory], "caiu para aviso: continua ativo (não crítico)")
        assert(m.update(ok, now: at(80)).active.isEmpty, "normal: sai")
        var chronic = AlertEngine()
        _ = chronic.update(p2, now: at(0))
        assert(chronic.update(p2, now: at(3600)).active.isEmpty, "padrão: pressão 2 crônica não alerta")
        var w = AlertEngine()
        w.memWarnEnabled = true
        _ = w.update(p2, now: at(0))
        assert(w.update(p2, now: at(299)).active.isEmpty, "aviso antes de 5 min")
        r = w.update(p2, now: at(300))
        assert(kinds(r.notify) == [.memory] && !r.active[0].critical, "aviso 5 min")
        _ = w.update(p4, now: at(310))
        assert(kinds(w.update(p4, now: at(370)).notify) == [.memory], "subiu para crítico: notifica mesmo no cooldown")

        // Disco: abaixo do MENOR entre 10% e 15 GB; sai acima do menor entre 12% e 18 GB.
        var d = AlertEngine()
        var low = ok; low.diskFree = 10_000_000_000          // 2% de 500 GB (< 15 GB)
        r = d.update(low, now: at(0))
        assert(kinds(r.notify) == [.disk] && r.active[0].title == "Disco quase cheio: 10 GB livres")
        var mid = ok; mid.diskFree = 16_000_000_000          // entre 15 e 18 GB: ainda dentro da histerese
        assert(kinds(d.update(mid, now: at(5)).active) == [.disk])
        assert(d.update(ok, now: at(10)).active.isEmpty, "15% livres: sai")
        var tiny = ok; tiny.diskTotal = 100_000_000_000; tiny.diskFree = 9_000_000_000   // 9% (< 10% de 100 GB)
        var e3 = AlertEngine()
        assert(kinds(e3.update(tiny, now: t0).active) == [.disk], "disco pequeno: abaixo de 10%")
        var big = ok; big.diskTotal = 2_000_000_000_000; big.diskFree = 150_000_000_000   // 7,5% de 2 TB, mas 150 GB livres
        var eBig = AlertEngine()
        assert(eBig.update(big, now: t0).active.isEmpty, "disco grande: 10% seria cedo demais")

        // Bateria: <= 20% sem carregar; de novo em <= 10%; carregar tira o alerta.
        var b = AlertEngine()
        var b19 = ok; b19.battery = 19
        r = b.update(b19, now: at(0))
        assert(kinds(r.notify) == [.battery] && r.active[0].title == "Bateria em 19%")
        var b21 = ok; b21.battery = 21
        assert(kinds(b.update(b21, now: at(5)).active) == [.battery], "21%: histerese até 25%")
        var b10 = ok; b10.battery = 10
        r = b.update(b10, now: at(60))
        assert(kinds(r.notify) == [.battery] && r.active[0].critical, "10%: notifica de novo")
        var plugged = b10; plugged.charging = true
        assert(b.update(plugged, now: at(70)).active.isEmpty, "carregando: sai")
        var noBat = ok; noBat.battery = nil
        var e4 = AlertEngine()
        assert(e4.update(noBat, now: t0).active.isEmpty, "Mac sem bateria")

        // thermalState: serious/critical na hora; volta ao normal e sai.
        var th = AlertEngine()
        var serious = ok; serious.thermal = 2
        var critical = ok; critical.thermal = 3
        r = th.update(serious, now: at(0))
        assert(kinds(r.notify) == [.thermal] && !r.active[0].critical)
        assert(th.update(critical, now: at(5)).active[0].critical)
        var fair = ok; fair.thermal = 1
        assert(th.update(fair, now: at(10)).active.isEmpty)

        // Vários ao mesmo tempo, ordem fixa.
        var all = hot; all.thermal = 3; all.battery = 5; all.diskFree = 1_000_000_000
        var x = AlertEngine()
        _ = x.update(all, now: at(0))
        assert(kinds(x.update(all, now: at(60)).active) == [.thermal, .temperature, .disk, .battery])
        print("ok")
    }
}
