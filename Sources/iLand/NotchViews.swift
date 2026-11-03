import SwiftUI
import AppKit

enum NotchMode: Equatable { case rest, ears, quick, overview }
enum OverviewTab: String, CaseIterable { case processes = "Processos", apps = "Por app", tree = "Árvore", ports = "Portas", charts = "Gráficos" }

enum QuickPage: Int, CaseIterable {
    case summary, sound, tools, shortcuts, capture, clipboard, shelf, notes, claude, machines, today, tunnels

    var symbol: String {
        switch self {
        case .summary: "thermometer.medium"
        case .sound: "speaker.wave.2.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .shortcuts: "bolt.fill"
        case .capture: "camera.viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .shelf: "tray.full.fill"
        case .notes: "note.text"
        case .claude: "sparkles"
        case .machines: "server.rack"
        case .today: "clock.fill"
        case .tunnels: "play.rectangle.on.rectangle"
        }
    }

    var title: String {
        switch self {
        case .summary: "Resumo"
        case .sound: "Som"
        case .tools: "Ferramentas"
        case .shortcuts: "Atalhos"
        case .capture: "Captura"
        case .clipboard: "Área de transferência"
        case .shelf: "Prateleira"
        case .notes: "Notas"
        case .claude: "Claude"
        case .machines: "Máquinas"
        case .today: "Hoje"
        case .tunnels: "Serviços"
        }
    }

    /// Aba dos Ajustes que a engrenagem da vista rápida abre nesta página. Sem ajuste próprio: Notch (mostrar/ordenar páginas).
    var settingsTab: SettingsTab {
        switch self {
        case .summary: .general
        case .capture: .capture
        case .claude: .models
        case .machines: .machines
        case .tunnels: .tunnels
        case .today: .clickup
        default: .notch
        }
    }
}

final class NotchUIModel: ObservableObject {
    @Published var mode: NotchMode = .rest
    @Published var epoch = 0                  // muda = a forma recomeça do repouso (descarta a animação de fechar em curso)
    @Published var faded = false              // fechando: a forma já chegou ao notch e some (sem faixa preta embaixo dele)
    @Published var tab: OverviewTab = .processes
    @Published var tabForward = true          // sentido da última troca de aba (para o slide)
    @Published var quickPage = 0              // página da vista rápida (QuickPage)
    @Published var dragX: CGFloat = 0         // quanto o dedo arrastou na vista rápida (a página acompanha)
    @Published var earNotice: String?          // aviso curto na orelha direita (ex.: "web-demo ▲"), some sozinho

    func selectTab(_ t: OverviewTab) {
        guard t != tab else { return }
        tabForward = (OverviewTab.allCases.firstIndex(of: t) ?? 0) > (OverviewTab.allCases.firstIndex(of: tab) ?? 0)
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { tab = t }
    }

    func stepTab(_ d: Int) {
        let all = OverviewTab.allCases, i = (all.firstIndex(of: tab) ?? 0) + d
        if all.indices.contains(i) { selectTab(all[i]) }
    }

    /// Todas as páginas na ordem escolhida nos Ajustes (o Resumo sempre primeiro).
    var pageOrder: [Int] { Prefs.order(UserDefaults.standard.string(forKey: Prefs.Key.pageOrder) ?? "", count: QuickPage.allCases.count) }

    /// Páginas visíveis, em ordem (o Resumo sempre; as outras podem ser escondidas nos Ajustes).
    var visiblePages: [Int] {
        let hidden = Prefs.hidden
        return pageOrder.filter { $0 == 0 || !hidden.contains($0) }
    }

    /// Arrasto com resistência quando não há página visível naquela direção.
    var resistedDrag: CGFloat {
        let v = visiblePages, i = v.firstIndex(of: quickPage) ?? 0
        return SwipeTracker.resisted(dragX, page: i, count: v.count)
    }

    /// Página visível vizinha de `page` (dir = -1 antes, +1 depois); nil na ponta. Funciona mesmo se `page` acabou de ser escondida.
    func neighbor(_ page: Int, _ dir: Int) -> Int? {
        let order = pageOrder, hidden = Prefs.hidden
        guard let i = order.firstIndex(of: page) else { return nil }
        let visible: (Int) -> Bool = { $0 == 0 || !hidden.contains($0) }
        return dir < 0 ? order[..<i].last(where: visible) : order[(i + 1)...].first(where: visible)
    }

    func stepPage(_ d: Int) {
        var p = quickPage
        for _ in 0..<abs(d) { guard let n = neighbor(p, d < 0 ? -1 : 1) else { break }; p = n }
        selectPage(p)
    }

    /// Páginas que existem de verdade durante um salto de mais de uma página (senão o slide passaria por páginas vazias).
    @Published var pageSpan: Set<Int>?
    private var spanGen = 0

    func selectPage(_ p: Int) {
        let v = visiblePages
        guard let n = v.contains(p) ? p : v.first else { return }   // página escondida nos Ajustes: volta ao Resumo
        let from = v.firstIndex(of: quickPage) ?? 0, to = v.firstIndex(of: n) ?? 0
        if abs(to - from) > 1 {
            pageSpan = Set(v[min(from, to)...max(from, to)])
            spanGen += 1
            let gen = spanGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * NotchLayout.slow) { [weak self] in
                if self?.spanGen == gen { self?.pageSpan = nil }
            }
        }
        withAnimation(.spring(response: 0.38 * NotchLayout.slow, dampingFraction: 1)) { quickPage = n; dragX = 0 }
    }
    @Published var notchWidth: CGFloat = 208
    @Published var notchHeight: CGFloat = 37.5
}

struct NotchActions {
    var openQuick: () -> Void
    var openOverview: () -> Void
}

enum Fmt {
    static func age(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m)min" }
        let h = m / 60
        return h < 24 ? "\(h)h\(String(format: "%02d", m % 60))" : "\(h / 24)d"
    }
    static func mem(_ kb: Int) -> String {
        kb >= 1_048_576 ? String(format: "%.1f GB", Double(kb) / 1_048_576) : "\(kb / 1024) MB"
    }
    static func bytes(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_073_741_824) }
    static func rate(_ b: Double) -> String {
        b >= 1_048_576 ? String(format: "%.1f MB/s", b / 1_048_576) : String(format: "%.0f KB/s", b / 1024)
    }
    static func temp(_ t: Double) -> String { t > 0 ? "\(Int(t))°" : "--" }
    /// "▲ 1 alerta · 2 suspeitos"
    static func issues(suspects: Int, alerts: Int, machines: Int = 0) -> String {
        var parts: [String] = []
        if machines > 0 { parts.append("\(machines) máquina\(machines == 1 ? "" : "s")") }
        if alerts > 0 { parts.append("\(alerts) alerta\(alerts == 1 ? "" : "s")") }
        if suspects > 0 { parts.append("\(suspects) suspeito\(suspects == 1 ? "" : "s")") }
        return "▲ " + parts.joined(separator: " · ")
    }
}

let secondary = Color.white.opacity(0.55)

struct NotchRoot: View {
    @ObservedObject var model: NotchUIModel
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var tools: ToolsModel
    let actions: NotchActions

    var body: some View {
        NotchBlobView(model: model, monitor: monitor, tools: tools, machines: tools.machines, agent: tools.agent, actions: actions)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }
}

struct SuspectRow: View {
    let suspect: Suspect
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        let p = suspect.sample
        HStack(spacing: 10) {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.appName ?? p.name).font(.system(size: 13)).foregroundColor(.white).lineLimit(1)
                Text("\(Int(p.cpu))% · rodando há \(Fmt.age(p.elapsed))")
                    .font(.system(size: 11)).foregroundColor(secondary)
                if !suspect.hint.isEmpty {
                    Text(suspect.hint).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.8)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if !suspect.chain.isEmpty { ChainView(chain: suspect.chain, tty: p.tty) }
                if !suspect.command.isEmpty {
                    Text(suspect.command).font(.system(size: 10, design: .monospaced)).foregroundColor(secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button("Ignorar") { monitor.ignore(pid: p.pid) }.buttonStyle(CapsuleStyle())
            if suspect.canKill { KillButton(targets: [p.target], quitApp: nil, monitor: monitor) }
        }
        .padding(.vertical, 8)
        .help(suspect.command)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5) }
    }
}

/// Alerta do Mac (temperatura, memória, disco, bateria): sem Encerrar, só "Ignorar 1h". Vermelho só para o thermalState crítico.
struct AlertRow: View {
    let alert: Alert
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(alert.dotColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(.system(size: 13)).foregroundColor(.white).lineLimit(1)
                Text(alert.message).font(.system(size: 11)).foregroundColor(secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Ignorar 1h") { monitor.snooze(alert.kind) }.buttonStyle(CapsuleStyle())
        }
        .frame(height: 48)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5) }
    }
}

/// Mesma coisa, na altura de uma linha da tabela da visão geral.
struct AlertTableRow: View {
    let alert: Alert
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(alert.dotColor).frame(width: 7, height: 7)
            Text(alert.title).lineLimit(1).layoutPriority(1)
            Text(alert.message).font(.system(size: 10)).foregroundColor(secondary).lineLimit(1)
            Spacer(minLength: 6)
            Button("Ignorar 1h") { monitor.snooze(alert.kind) }.buttonStyle(CapsuleStyle())
        }
        .font(.system(size: 12))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.14)))
    }
}

extension Alert {
    var dotColor: Color { kind == .thermal && critical ? .red : .orange }
}

struct CapsuleStyle: ButtonStyle {
    var tint: Color = .white
    var fill = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 11).padding(.vertical, fill ? 6 : 3)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0.14)))
    }
}

// MARK: - Visão geral

struct OverviewView: View {
    @ObservedObject var model: NotchUIModel
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        let s = monitor.stats ?? SystemStats()
        VStack(spacing: 10) {
            header(s)
            cards(s)
            tabs
            ZStack(alignment: .top) {
                Group {
                    switch model.tab {
                    case .charts: ChartsView(stats: s)
                    case .ports: PortsView(stats: s, monitor: monitor)
                    default: table(s)
                    }
                }
                .id(model.tab)
                .transition(.asymmetric(insertion: .move(edge: model.tabForward ? .trailing : .leading).combined(with: .opacity), removal: .opacity))
            }
            .clipped()
            Text(footer(s))
                .font(.system(size: 10)).foregroundColor(secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, NotchLayout.fillet + 14)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        // Altura fixa e ancorada no topo: se o conteúdo passar, corta embaixo e não deforma as curvas do notch.
        .frame(width: NotchLayout.overviewWidth, height: NotchLayout.fillet + NotchLayout.overviewHeight, alignment: .top)
    }

    private func footer(_ s: SystemStats) -> String {
        switch model.tab {
        case .charts: return "últimos 10 min · atualiza a cada 2 s · Esc fecha"
        case .ports:
            let p = s.ports ?? []
            return "\(p.count) portas · \(p.filter(\.entry.exposed).count) expostas na rede · atualiza a cada 5 s · Esc fecha"
        default: return "\(s.processes.count) processos · atualiza a cada 2 s · Esc fecha"
        }
    }

    private func header(_ s: SystemStats) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Fmt.temp(s.cpuTemp)).font(.system(size: 20, weight: .medium))
                Text("CPU").font(.system(size: 11)).foregroundColor(secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Fmt.temp(s.gpuTemp)).font(.system(size: 20, weight: .medium))
                Text("GPU").font(.system(size: 11)).foregroundColor(secondary)
            }
            Spacer()
            if s.thermalCritical { Text("● Mac limitando o desempenho").foregroundColor(.red).font(.system(size: 12)) }
            else if !s.suspects.isEmpty || !s.alerts.isEmpty { Text(Fmt.issues(suspects: s.suspects.count, alerts: s.alerts.count)).foregroundColor(.orange).font(.system(size: 12)) }
        }
        .foregroundColor(.white)
    }

    private func cards(_ s: SystemStats) -> some View {
        let m = s.metrics
        return HStack(spacing: 8) {
            Card(title: "CPU", big: "\(Int(m.cpuTotal))%") {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(m.cores.enumerated()), id: \.offset) { _, c in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.14))
                            RoundedRectangle(cornerRadius: 1.5).fill(c > 90 ? Color.orange : Color.white.opacity(0.85))
                                .frame(height: max(2, 26 * c / 100))
                        }
                        .frame(height: 26)
                    }
                }
            }
            Card(title: "Memória", big: "\(Fmt.bytes(m.memUsed))", unit: "/ \(Fmt.bytes(m.memTotal)) GB") {
                VStack(alignment: .leading, spacing: 3) {
                    Meter(fraction: m.memTotal > 0 ? Double(m.memUsed) / Double(m.memTotal) : 0, warn: m.pressure > 1)
                    Text("swap \(Fmt.bytes(m.swapUsed)) GB").font(.system(size: 10)).foregroundColor(secondary)
                }
            }
            Card(title: "Rede", big: Fmt.rate(m.netDown), unit: "↓") {
                Text("↑ \(Fmt.rate(m.netUp))").font(.system(size: 10)).foregroundColor(secondary)
            }
            Card(title: "Energia e disco", big: m.battery.map { "\($0)%" } ?? "—") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.battery == nil ? "sem bateria" : (m.charging ? "carregando" : "na bateria"))
                        .font(.system(size: 10)).foregroundColor(secondary)
                    Meter(fraction: m.diskUsedFraction, warn: m.diskUsedFraction > 0.9)
                }
            }
        }
    }

    private var tabs: some View {
        HStack {
            HStack(spacing: 2) {
                ForEach(OverviewTab.allCases, id: \.self) { t in
                    Text(t.rawValue).font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(model.tab == t ? 0.22 : 0)))
                        .foregroundColor(.white)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectTab(t) }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
            Spacer()
        }
    }

    private func rows(_ s: SystemStats) -> [OverviewRow] {
        let suspectPids = Set(s.suspects.map { $0.sample.pid })
        let byPid = Dictionary(s.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let me = getuid(), myPid = getpid()
        func killable(_ p: ProcSample) -> Bool { p.uid == me && !p.isProtected && p.pid != myPid }
        // O próprio processo e depois os pais: serve para achar o app com janela dono dele.
        func links(of p: ProcSample) -> [Origin.Link] {
            var out = [Origin.Link(pid: p.pid, name: p.name)]
            var cur = p
            while out.count < 8, let parent = byPid[cur.ppid], parent.pid > 1 {
                out.append(Origin.Link(pid: parent.pid, name: parent.name))
                cur = parent
            }
            return out
        }
        func row(_ p: ProcSample, name: String? = nil, sus: Suspect?) -> OverviewRow {
            OverviewRow(id: "p\(p.pid)", name: name ?? p.name, note: sus?.hint ?? "", cpu: p.cpu, rssKB: p.rssKB, age: p.elapsed,
                        suspect: sus, targets: [p.target], canKill: killable(p), links: links(of: p), tty: p.tty, quitApp: nil)
        }
        switch model.tab {
        case .processes:
            let top = s.processes.filter { !suspectPids.contains($0.pid) }.prefix(max(0, 7 - min(3, s.suspects.count) - shownAlerts(s).count))
            return s.suspects.prefix(3).map { row($0.sample, sus: $0) } + top.map { row($0, sus: nil) }
        case .apps:
            let groups = Dictionary(grouping: s.processes) { $0.appName ?? $0.name }
            return groups.map { key, ps in
                let sus = s.suspects.first { sp in ps.contains { $0.pid == sp.sample.pid } }
                let kill = ps.filter(killable)
                return OverviewRow(id: "a\(key)", name: key, note: ps.count > 1 ? "\(ps.count) processos" : "",
                                   cpu: ps.map(\.cpu).reduce(0, +), rssKB: ps.map(\.rssKB).reduce(0, +), age: ps.map(\.elapsed).max() ?? 0,
                                   suspect: sus, targets: kill.map(\.target), canKill: !kill.isEmpty,
                                   links: ps.prefix(6).flatMap(links(of:)), tty: sus?.sample.tty ?? "",
                                   quitApp: ps.lazy.compactMap { NSRunningApplication(processIdentifier: $0.pid) }.first { $0.activationPolicy == .regular })
            }
            .sorted { $0.cpu > $1.cpu }.prefix(7).map { $0 }
        case .tree:
            return s.processes.prefix(7).map { p in
                var chain = [p.appName ?? p.name]
                var cur = p
                while chain.count < 5, let parent = byPid[cur.ppid], parent.pid > 1 { chain.append(parent.appName ?? parent.name); cur = parent }
                if cur.ppid == 1 { chain.append("launchd") }
                return row(p, name: chain.reversed().joined(separator: " › "), sus: s.suspects.first { $0.sample.pid == p.pid })
            }
        case .charts, .ports:
            return []
        }
    }

    /// Alertas ativos entram como linhas no topo da aba Processos (até 2).
    private func shownAlerts(_ s: SystemStats) -> [Alert] { model.tab == .processes ? Array(s.alerts.prefix(2)) : [] }

    private func table(_ s: SystemStats) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer().frame(width: 7)
                Text("Processo").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 46, alignment: .trailing)
                Text("Memória").frame(width: 66, alignment: .trailing)
                Text("Há quanto").frame(width: 52, alignment: .trailing)
                Spacer().frame(width: 84)
            }
            .font(.system(size: 10)).foregroundColor(secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            ForEach(shownAlerts(s)) { AlertTableRow(alert: $0, monitor: monitor) }
            ForEach(rows(s)) { ProcTableRow(row: $0, monitor: monitor) }
        }
    }
}

struct OverviewRow: Identifiable {
    let id: String
    let name: String
    let note: String
    let cpu: Double
    let rssKB: Int
    let age: TimeInterval
    let suspect: Suspect?
    let targets: [ProcTarget]
    let canKill: Bool
    let links: [Origin.Link]
    let tty: String
    let quitApp: NSRunningApplication?   // app com janela: fecha com pedido educado (pergunta se quer salvar)
}

/// Clique no nome abre o app dono (e a aba do terminal, se for o caso). "Encerrar" aparece ao passar o mouse.
struct ProcTableRow: View {
    let row: OverviewRow
    @ObservedObject var monitor: SystemMonitor
    @State private var hover = false

    var body: some View {
        let app = AppFocus.gui(from: row.links[...])
        HStack(spacing: 6) {
            Circle().fill(row.suspect != nil ? Color.orange : .clear).frame(width: 7, height: 7)
            HStack(spacing: 5) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                    .underline(app != nil && hover)
                    .contentShape(Rectangle())
                    .onTapGesture { if let app { AppFocus.go(to: app, tty: row.tty) } }
                    .help(app.map { "Abrir \($0.localizedName ?? row.name)" } ?? "")
                if !row.note.isEmpty { Text(row.note).font(.system(size: 10)).foregroundColor(secondary).lineLimit(1) }
                if let sus = row.suspect, !sus.chain.isEmpty { ChainView(chain: sus.chain, tty: row.tty, compact: true).font(.system(size: 10)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(Int(row.cpu))%").frame(width: 46, alignment: .trailing)
            Text(Fmt.mem(row.rssKB)).frame(width: 66, alignment: .trailing)
            Text(Fmt.age(row.age)).frame(width: 52, alignment: .trailing)
            ZStack {
                if row.canKill && (hover || row.suspect != nil) { KillButton(targets: row.targets, quitApp: row.quitApp, monitor: monitor) }
            }
            .frame(width: 84, height: 20, alignment: .trailing)
        }
        .monospacedDigit()
        .font(.system(size: 12))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .frame(height: 28)   // altura fixa: o botão que aparece no hover não pode empurrar as outras linhas
        .background(RoundedRectangle(cornerRadius: 8).fill(row.suspect != nil ? Color.orange.opacity(0.14) : (hover ? Color.white.opacity(0.07) : .clear)))
        .onHover { hover = $0 }
    }
}

struct Card<Content: View>: View {
    let title: String
    let big: String
    var unit = ""
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundColor(secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(big).font(.system(size: 17, weight: .medium)).monospacedDigit().foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundColor(secondary) }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.09)))
    }
}

struct Meter: View {
    let fraction: Double
    var warn = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(warn ? Color.orange : Color.white.opacity(0.85)).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
    }
}
