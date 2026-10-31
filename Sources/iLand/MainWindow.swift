import SwiftUI
import AppKit

/// Janela do iLand (área geral): Assistente, Hoje, Máquinas, Memória e Ajustes, em tamanho grande.
/// Abre pelo menu da barra ("Abrir iLand"), pelo botão do notch, pelo atalho ⌃⌥⌘Espaço e por ILAND_WINDOW=… (depuração).
/// Escura como o notch. ILAND_WINDOW_SHOT=<arquivo.png> grava a janela (cacheDisplay, sem permissão de gravação de tela).
final class MainWindow {
    enum Section: String, CaseIterable, Identifiable {
        case assistant = "Assistente", today = "Hoje", machines = "Máquinas", memory = "Memória", settings = "Ajustes"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .assistant: "sparkles"
            case .today: "clock"
            case .machines: "server.rack"
            case .memory: "brain"
            case .settings: "gearshape"
            }
        }
        static func from(_ s: String) -> Section? {
            ["assistente": .assistant, "hoje": .today, "maquinas": .machines, "memoria": .memory, "ajustes": .settings][s.lowercased()]
        }
    }

    static let shared = MainWindow()
    private var window: NSWindow?
    private let selection = SectionModel()
    var tools: ToolsModel?
    var machines: MachinesMonitor? { tools?.machines }

    final class SectionModel: ObservableObject { @Published var current: Section = .assistant }

    func show(_ section: Section? = nil) {
        guard let tools else { return }
        if let section { selection.current = section }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "iLand"
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(white: 0.07, alpha: 1)
            w.minSize = NSSize(width: 820, height: 520)
            w.contentView = NSHostingView(rootView: MainView(sel: selection, tools: tools, agent: tools.agent).preferredColorScheme(.dark))
            w.center()
            if ProcessInfo.processInfo.environment["ILAND_WINDOW"] != nil { w.level = .floating }   // depuração: na frente de tudo
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        tools.agent.seen()
        if let path = ProcessInfo.processInfo.environment["ILAND_WINDOW_SHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["ILAND_WINDOW_SHOT_DELAY"] ?? "") ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.snapshot(to: path) }
        }
    }

    /// Foto da própria janela (para conferir a tela sem a permissão de gravação de tela).
    func snapshot(to path: String) { window?.snapshot(to: path) }
}

extension NSWindow {
    /// Depuração: grava o conteúdo da janela em PNG (cacheDisplay, sem permissão de gravação de tela).
    func snapshot(to path: String) {
        guard let v = contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// ILAND_WINDOW_SHOT=<arquivo.png>: grava esta janela depois de ILAND_WINDOW_SHOT_DELAY segundos (padrão 2,5).
    func debugShot() {
        guard let path = ProcessInfo.processInfo.environment["ILAND_WINDOW_SHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["ILAND_WINDOW_SHOT_DELAY"] ?? "") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.snapshot(to: path) }
    }
}

struct MainView: View {
    @ObservedObject var sel: MainWindow.SectionModel
    let tools: ToolsModel
    @ObservedObject var agent: AgentController

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { OrbView(state: agent.orb, size: 11); Text("iLand").font(.system(size: 15, weight: .semibold)) }
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
                ForEach(MainWindow.Section.allCases) { s in
                    Button { sel.current = s } label: {
                        Label(s.rawValue, systemImage: s.symbol).font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(sel.current == s ? 0.1 : 0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundColor(sel.current == s ? .white : secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(width: 180)
            .background(Color.white.opacity(0.03))
            Divider()
            Group {
                switch sel.current {
                case .assistant: AssistantScreen(agent: agent, tools: tools, brain: tools.brain, watch: tools.timerWatch, activity: tools.activity)
                case .today: ScreenCard { TodayPage(activity: tools.activity, watch: tools.timerWatch) }
                case .machines: ScreenCard { MachinesPage(machines: tools.machines) }
                case .memory: MemoryScreen()
                case .settings: SettingsScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(sel.current)
        }
        .foregroundColor(.white)
        .background(Color(white: 0.07))   // explícito: a foto de depuração (cacheDisplay) não desenha o fundo da janela
    }
}

/// As páginas do notch, maiores e centradas na janela.
struct ScreenCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .frame(width: 520, height: 300, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black))
            .padding(28)
    }
}

struct AssistantScreen: View {
    @ObservedObject var agent: AgentController
    let tools: ToolsModel
    @ObservedObject var brain: BrainClient
    @ObservedObject var watch: TimerWatch
    @ObservedObject var activity: ActivitySensor

    var body: some View {
        let current = activity.today.first { $0.project.hasPrefix("/") }.map { ProjectResolver.display($0.project) }   // só projeto de verdade (não "Arc")
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if agent.messages.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) { OrbView(state: agent.orb, size: 14); Text(Prefs.string(Prefs.Key.userName).isEmpty ? "Oi." : "Oi, \(Prefs.userName).").font(.system(size: 20, weight: .semibold)) }
                                    Text("Eu acompanho seu dia, seus projetos, o timer do ClickUp e suas tasks. Pergunte, ou espere: eu aviso quando algo pedir atenção.")
                                        .font(.system(size: 13)).foregroundColor(secondary)
                                }
                                .padding(.top, 30)
                            }
                            ForEach(agent.messages) { AgentMessageView(message: $0, agent: agent).id($0.id) }
                        }
                        .padding(20)
                    }
                    .onChange(of: agent.messages.last?.text) { _ in withAnimation { proxy.scrollTo(agent.messages.last?.id, anchor: .bottom) } }
                    .onAppear { proxy.scrollTo(agent.messages.last?.id, anchor: .bottom) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    AgentSuggestions(agent: agent, project: current)
                    HStack(spacing: 8) {
                        TextField("Fale com o assistente", text: $agent.draft)
                            .textFieldStyle(.plain).font(.system(size: 14))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                            .onSubmit { agent.send() }
                        Button(agent.busy ? "Parar" : "Enviar") { agent.busy ? agent.cancel() : agent.send() }
                            .buttonStyle(CapsuleStyle(tint: agent.busy ? .orange : .white))
                        Button {} label: { Image(systemName: "mic") }.buttonStyle(ChipStyle()).disabled(true).help("Voz: em breve")
                    }
                }
                .padding(16)
            }
            Divider()
            NowPanel(tools: tools, brain: brain, watch: watch, activity: activity, machines: tools.machines)
                .frame(width: 210)
        }
    }
}

/// Painel "Agora": projeto, timer, máquinas e custo do assistente hoje.
struct NowPanel: View {
    let tools: ToolsModel
    @ObservedObject var brain: BrainClient
    @ObservedObject var watch: TimerWatch
    @ObservedObject var activity: ActivitySensor
    @ObservedObject var machines: MachinesMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agora").font(.system(size: 12, weight: .semibold)).foregroundColor(secondary)
            item("Projeto com mais tempo hoje", activity.today.first.map { "\(ProjectResolver.display($0.project)) · \(TodayPage.hm($0.seconds))" } ?? "—")
            item("Timer do ClickUp", watch.lastEntry.map { "\($0.taskName) · desde \(DateFormatter.localizedString(from: $0.start, dateStyle: .none, timeStyle: .short))" } ?? "parado",
                 color: watch.card != nil ? .orange : .white)
            let bad = machines.entries.filter { $0.state.alertLevel > .ok }.count
            item("Máquinas", machines.entries.isEmpty ? "—" : (bad == 0 ? "\(machines.entries.count) ok" : "\(bad) com problema"), color: bad == 0 ? .green : .orange)
            item("Hoje no ar", TodayPage.hm(activity.today.reduce(0) { $0 + $1.seconds }))
            Spacer()
            Text("Assistente hoje: \(brain.tokensToday / 1000)k tokens · US$ \(String(format: "%.2f", brain.costToday))")
                .font(.system(size: 10)).foregroundColor(secondary)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.03))
    }

    private func item(_ label: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundColor(secondary)
            Text(value).font(.system(size: 12.5)).foregroundColor(color).lineLimit(2)
        }
    }
}

/// O que o assistente guardou (aprovado pela pessoa). Só lista nesta versão.
struct MemoryScreen: View {
    @State private var lines: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Memória do assistente").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Atualizar") { load() }.buttonStyle(CapsuleStyle())
            }
            Text("Correções e fatos que você aprovou. O assistente consulta isto antes de afirmar o que você fez.")
                .font(.system(size: 12)).foregroundColor(secondary)
            if lines.isEmpty { Text("Nada guardado ainda.").foregroundColor(secondary).padding(.top, 8) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lines, id: \.self) { l in
                        Text(l).font(.system(size: 13)).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                    }
                }
            }
        }
        .padding(24)
        .onAppear(perform: load)
    }
    private func load() { lines = BrainMemory.read().split(separator: "\n").map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) } }
}

/// Ajustes dentro da janela (as mesmas abas da janela de Ajustes, sem a segunda barra lateral).
struct SettingsScreen: View {
    @State private var tab: SettingsTab = .general
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) { ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 700)
            tab.view.frame(maxWidth: 620, alignment: .topLeading)
        }
        .padding(24)
    }
}
