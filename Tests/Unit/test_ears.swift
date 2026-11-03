// Uso: swiftc -parse-as-library Sources/iLand/EarDials.swift Tests/Unit/test_ears.swift -o /tmp/t_ears && /tmp/t_ears
import Foundation

@main struct EarsCheck {
    static func main() {
        let all: (EarItem) -> Bool = { _ in true }

        // Padrão = iLand de antes: sem timer, 5h e 7d; timer ligado com "passar à frente" vai para a esquerda.
        var d = EarDials(config: .standard)
        let noTimer: (EarItem) -> Bool = { $0 != .timer }
        assert(d.shown(.left, has: noTimer) == .usage5h && d.shown(.right, has: noTimer) == .usage7d)
        d.bringTimer()
        assert(d.shown(.left, has: all) == .timer)
        d.roll(.left, step: 1, has: all)   // rolar segue a pilha
        assert(d.shown(.left, has: all) == .usage5h)
        d.roll(.right, step: 1, has: all)   // lista de 1 item fica fixa
        assert(d.shown(.right, has: all) == .usage7d)

        // Cada lado gira sozinho, volta ao começo e pula item sem dado (nos dois sentidos).
        let cfg = EarConfig(left: [EarSlot(item: .cpu), EarSlot(item: .battery), EarSlot(item: .memory)],
                            right: [EarSlot(item: .clock), EarSlot(item: .network)])
        var c = EarDials(config: cfg)
        let noBattery: (EarItem) -> Bool = { $0 != .battery && $0 != .timer }
        assert(c.items(.left).first == .timer)   // timer fora das listas entra na esquerda
        assert(c.shown(.left, has: noBattery) == .cpu)   // timer sem dado sai da vez
        c.roll(.left, step: 1, has: noBattery); assert(c.shown(.left, has: noBattery) == .memory)
        c.roll(.left, step: 1, has: noBattery); assert(c.shown(.left, has: noBattery) == .cpu)
        c.roll(.left, step: -1, has: noBattery); assert(c.shown(.left, has: noBattery) == .memory)
        assert(c.shown(.right, has: all) == .clock)
        c.roll(nil, step: 1, has: noBattery)   // no notch: as duas
        assert(c.shown(.left, has: noBattery) == .cpu && c.shown(.right, has: all) == .network)

        // Único item sem dado: continua ele ("—"). Lista vazia: nada.
        let lone = EarDials(config: EarConfig(left: [EarSlot(item: .battery), EarSlot(item: .timer)], right: []))
        assert(lone.shown(.left, has: { _ in false }) == .battery && lone.shown(.right, has: all) == nil)

        // Vínculo: só no sentido marcado; "Vazio" apaga o outro lado até alguém rolar.
        let linked = EarConfig(left: [EarSlot(item: .usage5h, link: .item(.usage7d)), EarSlot(item: .cpu, link: .empty), EarSlot(item: .timer)],
                               right: [EarSlot(item: .clock), EarSlot(item: .usage7d, link: .item(.timer)), EarSlot(item: .gpuTemp)])
        var v = EarDials(config: linked)
        v.roll(.right, step: 1, has: all)   // direita chega no 7d: a esquerda vai para o timer
        assert(v.shown(.right, has: all) == .usage7d && v.shown(.left, has: all) == .timer)
        v.roll(.left, step: 1, has: all)    // esquerda chega no 5h: direita vai para o 7d (que não dispara de volta)
        assert(v.shown(.left, has: all) == .usage5h && v.shown(.right, has: all) == .usage7d)
        v.roll(.right, step: 1, has: all)   // o item apontado continua livre na catraca dele
        assert(v.shown(.right, has: all) == .gpuTemp && v.shown(.left, has: all) == .usage5h)
        v.roll(.left, step: 1, has: all)    // CPU com vínculo "Vazio"
        assert(v.shown(.left, has: all) == .cpu && v.shown(.right, has: all) == nil)
        v.roll(.right, step: 1, has: all)   // rolar o lado apagado volta a mostrar
        assert(v.shown(.right, has: all) != nil)

        // Último item visto com vínculo: vale ao abrir.
        assert(EarDials(config: linked, current: [.cpu, .clock]).shown(.right, has: all) == nil)

        // Conflito rolando as duas: ganha a esquerda.
        var w = EarDials(config: linked, current: [.timer, .clock])
        w.roll(nil, step: 1, has: all)      // esquerda chega no 5h (→ 7d), direita chega no 7d (→ timer)
        assert(w.shown(.left, has: all) == .usage5h && w.shown(.right, has: all) == .usage7d)

        // Ajustes: JSON vazio ou quebrado = padrão; ida e volta preserva.
        assert(EarConfig.decode("") == .standard && EarConfig.decode("{x") == .standard)
        var auto = linked; auto.autoSeconds = 5
        assert(EarConfig.decode(auto.json) == auto)
        print("ok")
    }
}
