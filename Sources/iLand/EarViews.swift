import SwiftUI

/// Dados que as orelhas mostram. `has` diz se um item tem dado agora (sem dado, a catraca pula o item).
struct EarData {
    let stats: SystemStats?
    let tools: ToolsModel
    let machines: MachinesMonitor
    let source: String   // claude | codex | none (Ajustes › Geral)

    func has(_ i: EarItem) -> Bool {
        let m = stats?.metrics
        switch i {
        case .timer: return tools.hasTimer && Prefs.string(Prefs.Key.timerWhere) != "menu"
        case .usage5h: return source != "none" && stats?.usage?.fiveHour != nil
        case .usage7d: return source != "none" && stats?.usage?.sevenDay != nil
        case .cpuTemp: return (stats?.cpuTemp ?? 0) > 0
        case .gpuTemp: return (stats?.gpuTemp ?? 0) > 0
        case .cpu, .network: return stats != nil
        case .memory: return (m?.memTotal ?? 0) > 0
        case .disk: return (m?.diskTotal ?? 0) > 0
        case .battery: return m?.battery != nil
        case .machines: return !machines.entries.isEmpty
        case .clock: return true
        }
    }
}

/// Um item numa orelha: rótulo pequeno cinza + valor, como o uso do Claude sempre foi.
struct EarItemView: View {
    let item: EarItem
    let data: EarData

    var body: some View {
        let s = data.stats, m = s?.metrics
        switch item {
        case .timer: EarTimerLabel(tools: data.tools, ticker: data.tools.ticker)
        case .usage5h, .usage7d:
            if data.source != "none" {
                let u = s?.usage, pct = ClaudeUsage.percent(item == .usage5h ? u?.fiveHour : u?.sevenDay)
                label(item == .usage5h ? "5h" : "7d", pct.map { "\($0)%" }, color: Self.level(pct, 80, 95), dim: u?.isStale() ?? false)
            }
        case .cpuTemp: label("CPU", (s?.cpuTemp).flatMap { $0 > 0 ? "\(Int($0))°" : nil }, color: Self.level((s?.cpuTemp).map(Int.init), 85, 95), first: false)
        case .gpuTemp: label("GPU", (s?.gpuTemp).flatMap { $0 > 0 ? "\(Int($0))°" : nil }, color: Self.level((s?.gpuTemp).map(Int.init), 85, 95), first: false)
        case .cpu: label("cpu", m.map { "\(Int($0.cpuTotal))%" }, color: Self.level(m.map { Int($0.cpuTotal) }, 80, 95))
        case .memory:
            let p = m.flatMap { $0.memTotal > 0 ? Int(Double($0.memUsed) / Double($0.memTotal) * 100) : nil }
            label("mem", p.map { "\($0)%" }, color: Self.level(p, 85, 95))
        case .disk:
            let p = m.flatMap { $0.diskTotal > 0 ? Int($0.diskUsedFraction * 100) : nil }
            label("disco", p.map { "\($0)%" }, color: Self.level(p, 85, 95))
        case .battery:
            let b = m?.battery
            label(m?.charging == true ? "⚡" : "bat", b.map { "\($0)%" }, color: m?.charging == true ? .white : (b ?? 100) <= 10 ? .red : (b ?? 100) <= 20 ? .orange : .white)
        case .network:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("↓" + Self.rate(m?.netDown)).foregroundColor(.white)
                Text("↑" + Self.rate(m?.netUp)).foregroundColor(secondary)
            }
            .font(.system(size: 11, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
        case .machines:
            let n = data.machines.issueCount
            label("máq", n == 0 ? "ok" : "▲\(n)", color: n == 0 ? .white : .orange)
        case .clock: label("", Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()), color: .white)
        }
    }

    /// Branco; laranja a partir de `warn`; vermelho a partir de `crit`.
    static func level(_ v: Int?, _ warn: Int, _ crit: Int) -> Color {
        switch v ?? 0 { case crit...: .red; case warn...: .orange; default: .white }
    }

    /// "1.2M", "30K", "0K" (bytes por segundo, curto para caber na orelha).
    static func rate(_ b: Double?) -> String {
        let v = b ?? 0
        return v >= 1_048_576 ? String(format: "%.1fM", v / 1_048_576) : String(format: "%.0fK", v / 1024)
    }

    /// Rótulo e valor. `first` false = valor antes do rótulo ("54° CPU", igual ao cabeçalho da vista rápida).
    private func label(_ l: String, _ v: String?, color: Color, dim: Bool = false, first: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if first && !l.isEmpty { Text(l).font(.system(size: 10)).foregroundColor(secondary) }
            Text(v ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(color).opacity(dim ? 0.4 : 1)
            if !first { Text(l).font(.system(size: 10)).foregroundColor(secondary) }
        }
        .lineLimit(1).fixedSize()
    }
}

/// Linha fina embaixo da orelha que enche até o próximo giro (modo "Passar a cada N s").
struct EarProgress: View {
    let seconds: Int
    let tick: Int
    @State private var fill: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            Capsule().fill(Color.white.opacity(0.35)).frame(width: g.size.width * fill, height: 1.5)
        }
        .frame(height: 1.5)
        .onAppear(perform: restart)
        .onChange(of: tick) { _ in restart() }
    }

    private func restart() {
        fill = 0
        DispatchQueue.main.async { withAnimation(.linear(duration: Double(seconds))) { fill = 1 } }
    }
}

/// Ajustes › Geral › Orelhas: as duas catracas, o modo de giro e o ▲N.
struct EarsSettings: View {
    @AppStorage(Prefs.Key.earDials) private var json = ""

    var body: some View {
        let cfg = EarConfig.decode(json)
        GlassSection("Orelhas", footer: "Cada orelha gira sozinha quando você rola com 2 dedos em cima dela. Rolar no notch gira as duas. \"Junto com\" leva o outro lado para um item quando este aparece.") {
            HStack(alignment: .top, spacing: 16) {
                column(.left, cfg)
                Divider()
                column(.right, cfg)
            }
            .padding(.vertical, 8)
            Divider()
            SettingRow("Girar") {
                Picker("", selection: Binding(get: { cfg.autoSeconds }, set: { v in save { $0.autoSeconds = v } })) {
                    Text("Só quando eu rolar").tag(0)
                    ForEach([3, 5, 10, 30], id: \.self) { Text("A cada \($0) s").tag($0) }
                }
                .labelsHidden().frame(width: 200)
            }
            SettingRow("Mostrar ▲N dos alertas", divider: false) {
                Toggle("", isOn: Binding(get: { cfg.showIssues }, set: { v in save { $0.showIssues = v } })).labelsHidden()
            }
        }
    }

    private func column(_ side: EarSide, _ cfg: EarConfig) -> some View {
        let slots = cfg.slots(side), others = cfg.slots(side.other).map(\.item)
        return VStack(alignment: .leading, spacing: 6) {
            Text(side == .left ? "Esquerda" : "Direita").font(Theme.overline).foregroundStyle(Theme.textTertiary)
            List {
                ForEach(slots) { slot in
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slot.item.title).font(Theme.label)
                            Picker("", selection: Binding(get: { slot.link }, set: { l in edit(side) { $0[$0.firstIndex { $0.id == slot.id }!].link = l } })) {
                                Text("Sozinho").tag(EarLink?.none)
                                Text("Junto com: nada").tag(EarLink?.some(.empty))
                                ForEach(others) { Text("Junto com: \($0.title)").tag(EarLink?.some(.item($0))) }
                            }
                            .labelsHidden().controlSize(.small).frame(maxWidth: 200)
                        }
                        Spacer()
                        Button { edit(side) { $0.removeAll { $0.id == slot.id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("Tirar da lista")
                    }
                    .frame(height: 48)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets())
                }
                .onMove { from, to in edit(side) { $0.move(fromOffsets: from, toOffset: to) } }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
            .frame(height: CGFloat(slots.count) * 48)
            Menu("Adicionar") {
                ForEach(EarItem.allCases.filter { i in !slots.contains { $0.item == i } }) { i in
                    Button(i.title) { edit(side) { $0.append(EarSlot(item: i)) } }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func edit(_ side: EarSide, _ change: (inout [EarSlot]) -> Void) {
        save { c in
            if side == .left { change(&c.left) } else { change(&c.right) }
            // Vínculo para um item que saiu da outra lista não vale mais.
            let l = Set(c.left.map(\.item)), r = Set(c.right.map(\.item))
            for i in c.left.indices { if case .item(let t) = c.left[i].link, !r.contains(t) { c.left[i].link = nil } }
            for i in c.right.indices { if case .item(let t) = c.right[i].link, !l.contains(t) { c.right[i].link = nil } }
        }
    }

    private func save(_ change: (inout EarConfig) -> Void) {
        var c = EarConfig.decode(json)
        change(&c)
        json = c.json
    }
}
