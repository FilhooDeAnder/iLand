// Uso: swiftc -parse-as-library Sources/iLand/Pomodoro.swift Sources/iLand/SwipeTracker.swift Tests/Unit/test_pomodoro.swift -o /tmp/t_pomo && /tmp/t_pomo
import Foundation

@main struct PomodoroCheck {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

        // Pomodoro: foco -> pausa -> foco ... pausa longa no 4º foco.
        var p = PomodoroEngine()
        assert(p.isIdle && p.remaining(now: t0) == nil)
        p.start(now: t0)
        assert(p.remaining(now: at(60)) == 24 * 60 && p.phase == .focus)
        assert(p.tick(now: at(1499)) == nil)
        assert(p.tick(now: at(1500)) == .focus && p.phase == .shortBreak && p.isRunning, "foco acabou: pausa de 5 min")
        assert(p.remaining(now: at(1500)) == 300)
        assert(p.tick(now: at(1800)) == .shortBreak && p.phase == .focus)
        var q = PomodoroEngine(); q.start(now: t0)
        var now = t0
        for i in 1...4 { now = now.addingTimeInterval(q.duration(.focus)); assert(q.tick(now: now) == .focus); if i < 4 { assert(q.phase == .shortBreak); now = now.addingTimeInterval(300); assert(q.tick(now: now) == .shortBreak) } }
        assert(q.phase == .longBreak && q.focusDone == 4, "4º foco: pausa longa")

        // Pausar e retomar mantém o que faltava.
        var r = PomodoroEngine(); r.start(now: t0); r.pause(now: at(600))
        assert(r.state == .paused(remaining: 900) && r.tick(now: at(99999)) == nil, "pausado não avança")
        r.start(now: at(1000)); assert(r.remaining(now: at(1000)) == 900)
        r.skip(now: at(1000)); assert(r.phase == .shortBreak && r.focusDone == 0, "pular não conta como foco concluído")
        r.reset(); assert(r.isIdle && r.phase == .focus && r.focusDone == 0)

        // Cronômetro.
        var w = Stopwatch(); assert(w.isIdle)
        w.start(now: t0); assert(w.elapsed(now: at(5)) == 5)
        w.pause(now: at(10)); assert(w.elapsed(now: at(99)) == 10 && !w.isRunning)
        w.start(now: at(100)); assert(w.elapsed(now: at(103)) == 13)
        w.reset(); assert(w.isIdle && w.elapsed(now: at(200)) == 0)

        // Cafeína.
        var c = Caffeine(); assert(!c.isOn && c.remaining(now: t0) == nil)
        c.turnOn(for: 1800, now: t0); assert(c.isOn && c.remaining(now: at(600)) == 1200)
        assert(!c.expire(now: at(1799)) && c.expire(now: at(1800)) && !c.isOn)
        c.turnOn(for: nil, now: t0); assert(c.remaining(now: at(1e9)) == .infinity && !c.expire(now: at(1e9)))
        c.turnOff(); assert(!c.isOn)

        // Formatos.
        assert(TimeFmt.clock(1450) == "24:10" && TimeFmt.clock(3723) == "1:02:03" && TimeFmt.clock(-5) == "00:00")
        assert(TimeFmt.stopwatch(12.34) == "00:12.3" && TimeFmt.stopwatch(75.0) == "01:15.0")

        // Gesto: horizontal decide, vertical passa, limiar, direção, resistência.
        var s = SwipeTracker(); s.begin()
        assert(s.move(dx: -4, dy: 0) == false && s.intent == .undecided, "ainda não decidiu")
        assert(s.move(dx: -20, dy: 2) == true && s.intent == .horizontal && s.offset == -24, "decidiu horizontal e já conta o que andou")
        _ = s.move(dx: -50, dy: 0); assert(s.end() == 1, "dedos para a esquerda: próxima página")
        s.begin(); _ = s.move(dx: 30, dy: 1); _ = s.move(dx: 40, dy: 0); assert(s.end() == -1, "para a direita: anterior")
        s.begin(); _ = s.move(dx: 20, dy: 0); _ = s.move(dx: 10, dy: 0); assert(s.end() == 0, "curto demais: fica")
        s.begin(); assert(s.move(dx: 1, dy: 30) == false && s.intent == .vertical && s.move(dx: 50, dy: 0) == false && s.end() == 0, "vertical: não é nosso")
        s.begin(); _ = s.move(dx: 1, dy: -20); _ = s.move(dx: 0, dy: -45); assert(s.end() == 0 && s.lastWasUp, "dedos para cima: voltar")
        s.begin(); _ = s.move(dx: 0, dy: -20); _ = s.move(dx: 0, dy: -10); _ = s.end(); assert(!s.lastWasUp, "curto demais")
        s.begin(); _ = s.move(dx: 0, dy: 30); _ = s.move(dx: 0, dy: 40); _ = s.end(); assert(!s.lastWasUp, "para baixo não volta")
        s.begin(); _ = s.move(dx: -40, dy: 0); _ = s.move(dx: -40, dy: -60); _ = s.end(); assert(!s.lastWasUp, "horizontal não é voltar")
        s.begin(); _ = s.move(dx: 0, dy: 30); _ = s.move(dx: 0, dy: 40); _ = s.end(); assert(s.lastWasDown && !s.lastWasUp, "dedos para baixo: entrar")
        s.begin(); _ = s.move(dx: 0, dy: -30); _ = s.move(dx: 0, dy: -40); _ = s.end(); assert(!s.lastWasDown && s.lastWasUp)
        assert(SwipeTracker.resisted(100, page: 0, count: 3) == 25 && SwipeTracker.resisted(-100, page: 2, count: 3) == -25)
        assert(SwipeTracker.resisted(-100, page: 0, count: 3) == -100 && SwipeTracker.resisted(100, page: 1, count: 3) == 100)
        print("ok")
    }
}
