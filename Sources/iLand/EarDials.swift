import Foundation

/// O que pode aparecer numa orelha. Só dado que o iLand já coleta.
enum EarItem: String, Codable, CaseIterable, Identifiable {
    case timer, usage5h, usage7d, cpuTemp, gpuTemp, cpu, memory, disk, battery, network, machines, clock, clickup, media
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timer: "Pomodoro ou cronômetro"
        case .usage5h: "Uso de 5 h"
        case .usage7d: "Uso de 7 dias"
        case .cpuTemp: "Temperatura da CPU"
        case .gpuTemp: "Temperatura da GPU"
        case .cpu: "CPU %"
        case .memory: "Memória"
        case .disk: "Disco"
        case .battery: "Bateria"
        case .network: "Rede"
        case .machines: "Máquinas"
        case .clock: "Hora"
        case .clickup: "Task do ClickUp"
        case .media: "Música tocando"
        }
    }
}

/// Para onde o outro lado vai quando um item chega: um item da outra lista ou nada.
enum EarLink: Codable, Hashable { case empty, item(EarItem) }

struct EarSlot: Codable, Equatable, Identifiable {
    var id = UUID()
    var item: EarItem
    var link: EarLink? = nil
}

enum EarSide: Int { case left, right
    var other: EarSide { self == .left ? .right : .left }
}

/// Ajustes das orelhas (Prefs `earDials`, JSON). `autoSeconds` 0 = parado: só gira quando a pessoa rola.
struct EarConfig: Codable, Equatable {
    var left: [EarSlot]
    var right: [EarSlot]
    var autoSeconds = 0
    var showIssues = true

    /// Igual ao iLand antes das catracas: timer ou 5 h à esquerda, 7 dias à direita.
    static let standard = EarConfig(left: [EarSlot(item: .timer), EarSlot(item: .usage5h)], right: [EarSlot(item: .usage7d)])

    static func decode(_ json: String) -> EarConfig {
        json.isEmpty ? standard : (try? JSONDecoder().decode(EarConfig.self, from: Data(json.utf8))) ?? standard
    }
    var json: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    func slots(_ s: EarSide) -> [EarSlot] { s == .left ? left : right }
}

/// As duas catracas, como as rodas de um cadeado de segredo. Puro: quem diz se um item tem dado agora é o chamador.
/// Regras (spec 2026-11-03-orelhas-catraca): item sem dado sai da vez; o vínculo do item que chega manda no outro lado;
/// rolando as duas, ganha a esquerda; o timer fora das listas entra na esquerda.
/// Item com vínculo só aparece com o par à vista no outro lado (decisão de 2026-11-04). Sem o par, sai da vez.
struct EarDials {
    var config: EarConfig
    private(set) var current: [EarItem?] = [nil, nil]   // item escolhido de cada lado (o último visto)
    private(set) var blank = [false, false]             // lado apagado por um vínculo "Vazio"
    private(set) var lead = EarSide.left                // último lado rolado: o vínculo dele manda no outro

    init(config: EarConfig, current: [EarItem?] = [nil, nil]) {
        self.config = config
        self.current = current.count == 2 ? current : [nil, nil]
        // O último item visto pode ter vínculo: vale ao abrir também (a esquerda primeiro, como ao rolar as duas).
        if let s = [EarSide.left, .right].first(where: { s in self.current[s.rawValue].map { link(for: $0, on: s) != nil } ?? false }),
           let item = self.current[s.rawValue] { follow(s, item); lead = s }
    }

    /// Lista que gira de cada lado. O timer que não está em nenhuma lista entra no começo da esquerda.
    func items(_ s: EarSide) -> [EarItem] {
        let l = config.slots(s).map(\.item)
        let orphanTimer = s == .left && !config.left.contains { $0.item == .timer } && !config.right.contains { $0.item == .timer }
        return orphanTimer ? [.timer] + l : l
    }

    /// O que a orelha mostra. nil = nada (lista vazia, "Vazio" ou só itens sem o par).
    /// O lado `lead` mostra o item dele. O outro lado pula item com vínculo cujo par não está à vista,
    /// exceto o item que o próprio `lead` pediu.
    func shown(_ s: EarSide, has: (EarItem) -> Bool) -> EarItem? {
        guard let b = base(s, has: has) else { return nil }
        if s == lead { return b }
        let l = base(lead, has: has)
        if let l, case .item(let t) = link(for: l, on: lead), t == b { return b }
        let paired: (EarItem) -> Bool = { i in
            if case .item(let t) = link(for: i, on: s) { return l == t }
            return true
        }
        if paired(b) { return b }
        return next(items(s), from: b, step: 1) { has($0) && paired($0) }
    }

    /// Item escolhido de um lado, sem olhar o outro. Sem dado: o próximo com dado; nenhum com dado: o escolhido ("—").
    private func base(_ s: EarSide, has: (EarItem) -> Bool) -> EarItem? {
        let l = items(s)
        guard !blank[s.rawValue], !l.isEmpty else { return nil }
        let cur = current[s.rawValue].flatMap { l.contains($0) ? $0 : nil } ?? l[0]
        if has(cur) { return cur }
        return next(l, from: cur, step: 1, has: has) ?? cur
    }

    /// Gira um lado (ou os dois, com `side` nil: rolar no notch ou o giro automático). `step` +1 próximo, -1 anterior.
    mutating func roll(_ side: EarSide?, step: Int, has: (EarItem) -> Bool) {
        let sides: [EarSide] = side.map { [$0] } ?? [.left, .right]
        var arrived: [(EarSide, EarItem)] = []
        for s in sides {
            let l = items(s)
            guard let from = shown(s, has: has) ?? current[s.rawValue] ?? l.first else { continue }
            if let n = next(l, from: from, step: step, has: has) { current[s.rawValue] = n; arrived.append((s, n)) }
        }
        blank = [false, false]   // o "Vazio" vale só enquanto o item que o pediu está à vista
        // Rolando as duas, o primeiro vínculo na ordem esquerda, direita ganha. O lado forçado não dispara o próprio vínculo.
        if let (s, item) = arrived.first(where: { link(for: $0.1, on: $0.0) != nil }) { follow(s, item); lead = s }
        else { lead = side ?? .left }
    }

    /// Timer ligado com "passar à frente": vai para o timer na catraca dele (a esquerda, se ele está fora das listas).
    mutating func bringTimer() {
        let s: EarSide = items(.left).contains(.timer) ? .left : .right
        guard items(s).contains(.timer) else { return }
        current[s.rawValue] = .timer
        blank = [false, false]
        lead = s
        follow(s, .timer)
    }

    private func link(for item: EarItem, on s: EarSide) -> EarLink? {
        config.slots(s).first { $0.item == item }?.link
    }

    private mutating func follow(_ s: EarSide, _ item: EarItem) {
        let o = s.other
        switch link(for: item, on: s) {
        case .empty: blank[o.rawValue] = true
        case .item(let target) where items(o).contains(target): current[o.rawValue] = target
        default: break
        }
    }

    /// Próximo item com dado depois de `from`, dando a volta. nil se nenhum outro tem dado.
    private func next(_ l: [EarItem], from: EarItem, step: Int, has: (EarItem) -> Bool) -> EarItem? {
        guard let i = l.firstIndex(of: from), l.count > 1 else { return nil }
        for k in 1..<l.count {
            let c = l[((i + k * (step < 0 ? -1 : 1)) % l.count + l.count) % l.count]
            if has(c) { return c }
        }
        return nil
    }
}
