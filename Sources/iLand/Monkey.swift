import AppKit

/// Teste do macaco (depuração): `ILAND_MONKEY=<semente>[,<segundos>]` mexe o mouse de verdade sobre o notch,
/// passa por cima dos ícones, rola, troca de modo, de página e de aba, ao acaso mas com semente (a mesma semente
/// repete o mesmo caminho). Nunca clica: um clique ao acaso pode encerrar um processo.
/// Um vigia mede quanto tempo a fila principal fica travada. No fim, fica 30 s parado (a CPU precisa voltar ao normal),
/// grava monkey.json em DebugOut.dir e fecha o app.
/// O mouse de verdade só mexe com a permissão de Acessibilidade; sem ela, o macaco só troca modo, página e aba.
@MainActor
final class Monkey {
    struct Report: Codable {
        var seed: UInt64, seconds: Double, events = 0, moves = 0, realMouse = false
        var stalls250 = 0, stallMaxMs = 0.0, memStartMB = 0.0, memEndMB = 0.0, memPeakMB = 0.0
        var restCpuPct = 0.0   // CPU nos 30 s parado depois do macaco: precisa voltar ao normal (timer ou animação presa?)
    }

    /// Gerador simples com semente (SplitMix64): o mesmo número dá a mesma sequência.
    struct Rng: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476C_E5B9_1CE5
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let controller: NotchController
    private var rng: Rng
    private var report: Report
    private var timer: Timer?
    private let start = Date()
    private let watch = StallWatch()
    private let home = NSEvent.mouseLocation

    static func startIfAsked(_ controller: NotchController) -> Monkey? {
        guard let v = ProcessInfo.processInfo.environment["ILAND_MONKEY"] else { return nil }
        let p = v.split(separator: ",")
        let m = Monkey(controller, seed: p.first.flatMap { UInt64($0) } ?? 1, seconds: p.dropFirst().first.flatMap { Double($0) } ?? 60)
        m.run()
        return m
    }

    private init(_ c: NotchController, seed: UInt64, seconds: Double) {
        controller = c
        rng = Rng(s: seed)
        report = Report(seed: seed, seconds: seconds)
        report.realMouse = AXIsProcessTrusted()
    }

    private func run() {
        watch.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        let t = Date().timeIntervalSince(start)
        if report.memStartMB == 0, t > 10 { report.memStartMB = Self.memMB() }   // depois de abrir as páginas uma vez
        report.memPeakMB = max(report.memPeakMB, Self.memMB())
        if t > report.seconds { finish(); return }
        report.events += 1
        guard let g = NotchGeometry.current() else { return }
        // A área do notch aberto: o retângulo da ilha mais uma folga, para sair e voltar também.
        // Em repouso o visibleRect é .zero, e a união com ele iria até o canto (0,0) da tela.
        let v = controller.visibleRect
        let r = (v.isEmpty ? g.hoverZone : v.union(g.hoverZone)).insetBy(dx: -40, dy: -40)
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<55: move(to: point(in: r))
        case 55..<75: sweep(across: r)
        case 75..<83: scroll(at: point(in: r))
        case 83..<90: controller.setMode([NotchMode.rest, .ears, .quick, .overview].randomElement(using: &rng)!)
        case 90..<96: if let p = controller.model.visiblePages.randomElement(using: &rng) { controller.model.selectPage(p) }
        default: controller.model.selectTab(OverviewTab.allCases.randomElement(using: &rng)!)
        }
    }

    private func point(in r: NSRect) -> NSPoint {
        NSPoint(x: CGFloat.random(in: r.minX...r.maxX, using: &rng), y: CGFloat.random(in: r.minY...r.maxY, using: &rng))
    }

    /// Passada rápida na horizontal, como arrastar o mouse por cima da barra de ícones.
    private func sweep(across r: NSRect) {
        let y = CGFloat.random(in: r.minY...r.maxY, using: &rng)
        let leftToRight = Bool.random(using: &rng)
        for i in 0...12 {
            let f = CGFloat(i) / 12
            move(to: NSPoint(x: r.minX + (leftToRight ? f : 1 - f) * r.width, y: y))
        }
    }

    private func move(to p: NSPoint) {
        report.moves += 1
        guard report.realMouse, let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: Self.quartz(p), mouseButton: .left) else { return }
        e.post(tap: .cghidEventTap)
    }

    private func scroll(at p: NSPoint) {
        guard report.realMouse else { return }
        move(to: p)
        let dx = Int32.random(in: -30...30, using: &rng), dy = Int32.random(in: -30...30, using: &rng)
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    /// AppKit conta y de baixo para cima; o Quartz, de cima para baixo, a partir da tela principal.
    private static func quartz(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    private static func memMB() -> Double { Double(ProcessFootprint.bytes(getpid()) ?? 0) / 1_048_576 }

    private func finish() {
        timer?.invalidate()
        move(to: home)
        controller.setMode(.rest)
        if report.memStartMB == 0 { report.memStartMB = Self.memMB() }   // teste com menos de 10 s
        let s = watch.stop()
        report.stalls250 = s.count; report.stallMaxMs = s.maxMs
        let cpu0 = Self.cpuSeconds(), t0 = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
            report.restCpuPct = ((Self.cpuSeconds() - cpu0) / Date().timeIntervalSince(t0) * 1000).rounded() / 10
            report.memEndMB = Self.memMB()
            save()
        }
    }

    /// CPU do app e dos filhos que ele já terminou (du, ps, sensors).
    private static func cpuSeconds() -> Double {
        var a = rusage(), b = rusage()
        getrusage(RUSAGE_SELF, &a); getrusage(RUSAGE_CHILDREN, &b)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(a.ru_utime) + s(a.ru_stime) + s(b.ru_utime) + s(b.ru_stime)
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(report) {
            try? d.write(to: DebugOut.dir.appendingPathComponent("monkey.json"))
            print(String(decoding: d, as: UTF8.self))
        }
        NSApp.terminate(nil)
    }
}

/// Vigia da fila principal: a cada 50 ms pede um bloco na main e mede quanto ele demora para rodar.
final class StallWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false, count = 0, maxMs = 0.0

    func start() {
        running = true
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let t0 = Date(), done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let ms = Date().timeIntervalSince(t0) * 1000
                lock.withLock {
                    maxMs = max(maxMs, ms)
                    if ms > 250 { count += 1 }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() -> (count: Int, maxMs: Double) {
        lock.withLock { running = false; return (count, (maxMs * 10).rounded() / 10) }
    }
}
