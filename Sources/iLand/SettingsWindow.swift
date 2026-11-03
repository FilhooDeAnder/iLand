import SwiftUI
import AppKit
import ServiceManagement

/// Janela de Ajustes (fora do notch). Abre pelo clique direito no ícone da barra de menus.
/// Barra de título transparente e conteúdo até a borda: barra lateral de vidro sobre o fundo com atmosfera.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    final class Selection: ObservableObject {
        // depuração: ILAND_SETTINGS=geral|perfil|modelos|projetos|máquinas|clickup|notch|sobre abre a janela já nessa aba
        @Published var tab: SettingsTab = SettingsTab.allCases.first { $0.rawValue.lowercased() == ProcessInfo.processInfo.environment["ILAND_SETTINGS"] } ?? .general
    }
    private let selection = Selection()

    static let size = NSSize(width: 880, height: 640)

    func show(_ tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Ajustes do iLand"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: SettingsView(sel: selection))
            w.center()
            if ProcessInfo.processInfo.environment["ILAND_SETTINGS"] != nil { w.level = .floating }   // depuração: aparece mesmo com outro app na frente
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.debugShot()
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "Geral", capture = "Captura", privacy = "Privacidade", profile = "Perfil", models = "Modelos", projects = "Projetos", machines = "Máquinas", tunnels = "Serviços", clickup = "ClickUp",
         tools = "Ferramentas", notch = "Notch", about = "Sobre"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .capture: "camera.viewfinder"
        case .privacy: "hand.raised.fill"
        case .profile: "person.crop.circle.fill"
        case .models: "sparkles"
        case .projects: "folder.fill"
        case .machines: "server.rack"
        case .tunnels: "play.rectangle.on.rectangle"
        case .clickup: "checklist"
        case .tools: "wrench.and.screwdriver.fill"
        case .notch: "rectangle.topthird.inset.filled"
        case .about: "info.circle.fill"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .general: GeneralSettings()
        case .capture: CaptureSettings()
        case .privacy: PrivacySettings()
        case .profile: ProfileSettings()
        case .models: ModelsSettings()
        case .projects: ProjectsSettings()
        case .machines: MachinesSettings(monitor: MainWindow.shared.machines)
        case .tunnels: TunnelsSettings(manager: MainWindow.shared.tools?.tunnels)
        case .clickup: ClickUpSettings()
        case .tools: ToolsSettings()
        case .notch: NotchSettings()
        case .about: AboutSettings()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var sel: SettingsWindow.Selection

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(sel: sel)
            sel.tab.view
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(sel.tab)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.18), value: sel.tab)
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .background(AtmosphereBackground())   // explícito: a foto de depuração (cacheDisplay) não desenha o fundo da janela
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
    }
}

/// Barra lateral: um bloco de vidro com os itens; o item escolhido ganha uma pílula de vidro com o acento.
struct SettingsSidebar: View {
    @ObservedObject var sel: SettingsWindow.Selection
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "capsule.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text("iLand").font(.system(size: 20, weight: .heavy, design: .rounded))
            }
            .padding(.horizontal, 12).padding(.top, 34).padding(.bottom, 18)
            ForEach(SettingsTab.allCases) { t in
                let on = sel.tab == t
                Button { sel.tab = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.symbol).font(.system(size: 13, weight: .semibold)).frame(width: 20)
                            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        Text(t.rawValue).font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background {
                        if on { Color.clear.glassSurface(cornerRadius: 12).matchedGeometryEffect(id: "sel", in: ns) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("v\(Updater.current)").font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(12)
        }
        .padding(10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .glassSurface(cornerRadius: 26)
        .padding(10)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: sel.tab)
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.Key.earsSource) private var earsSource = "claude"
    @AppStorage(Prefs.Key.quickHideDelay) private var delay = 1.2
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""

    var body: some View {
        SettingsPage(symbol: "gearshape.fill", title: "Geral", subtitle: "Como o iLand abre e o que aparece no notch.") {
            GlassSection("Início") {
                SettingRow("Abrir o iLand ao entrar no Mac", detail: loginError.isEmpty ? nil : loginError, divider: false) {
                    Toggle("", isOn: Binding(get: { launchAtLogin }, set: setLogin)).labelsHidden()
                }
            }
            EarsSettings()
            GlassSection("Uso de 5 h e 7 dias") {
                SettingRow("De qual conta", detail: "Vale para os itens Uso de 5 h e Uso de 7 dias das orelhas.", divider: false) {
                    Picker("", selection: $earsSource) {
                        Text("Claude").tag("claude"); Text("Codex").tag("codex"); Text("Nada").tag("none")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
            }
            GlassSection("Vista rápida") {
                SettingRow("Recolher depois de \(delay.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "pt_BR")))) s", detail: "Tempo que a vista rápida espera depois que o mouse sai dela.", divider: false) {
                    Slider(value: $delay, in: 0.5...5, step: 0.1).frame(width: 200)
                }
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = "Não consegui mudar: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct NotchSettings: View {
    @AppStorage(Prefs.Key.hoverEars) private var hoverEars = true
    @AppStorage(Prefs.Key.shelfOnDrag) private var shelfOnDrag = true
    @AppStorage(Prefs.Key.otherScreens) private var otherScreens = false
    @AppStorage(Prefs.Key.hiddenPages) private var hiddenCSV = ""
    @AppStorage(Prefs.Key.pageOrder) private var orderCSV = ""

    var body: some View {
        let hidden = Prefs.hiddenPages(hiddenCSV)
        let movable = Prefs.order(orderCSV, count: QuickPage.allCases.count).filter { $0 != 0 }
        SettingsPage(symbol: "rectangle.topthird.inset.filled", title: "Notch", subtitle: "O que abre a ilha e quais páginas aparecem nela.") {
            GlassSection("Comportamento") {
                SettingRow("Passar o mouse no notch abre as orelhas") { Toggle("", isOn: $hoverEars).labelsHidden() }
                SettingRow("Arrastar um arquivo até o notch abre a prateleira") { Toggle("", isOn: $shelfOnDrag).labelsHidden() }
                SettingRow("Mostrar nas outras telas", detail: "Desenha um notch no topo das telas que não têm (monitor externo). A ilha abre na tela do mouse.", divider: false) {
                    Toggle("", isOn: $otherScreens).labelsHidden()
                }
            }
            GlassSection("Páginas da vista rápida", footer: "Arraste pelas bolinhas para mudar a ordem. Desligada, a página some da barra de ícones e do arrasto.") {
                row(.summary, on: true, fixed: true) { _ in }
                List {
                    ForEach(movable, id: \.self) { raw in
                        if let p = QuickPage(rawValue: raw) {
                            row(p, on: !hidden.contains(raw), fixed: false) { on in
                                var h = hidden
                                if on { h.remove(raw) } else { h.insert(raw) }
                                hiddenCSV = Prefs.csv(h)
                            }
                            .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets())
                        }
                    }
                    .onMove { from, to in
                        var o = movable
                        o.move(fromOffsets: from, toOffset: to)
                        orderCSV = Prefs.orderCSV([0] + o)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
                .frame(height: CGFloat(movable.count) * 44)
            }
            HStack {
                Spacer()
                Button("Voltar à ordem original") { orderCSV = "" }.glassButton().disabled(orderCSV.isEmpty)
            }
        }
    }

    /// Linha de uma página: bolinhas de arrastar, nome e liga/desliga. O Resumo é fixo (sem bolinhas, sempre ligado).
    private func row(_ p: QuickPage, on: Bool, fixed: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.textTertiary).opacity(fixed ? 0 : 1).frame(width: 16)
            Image(systemName: p.symbol).foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary).frame(width: 20)
            Text(p.title).font(Theme.label).foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            Spacer()
            if fixed { Text("sempre").font(Theme.caption).foregroundStyle(Theme.textTertiary) }
            else { Toggle("", isOn: Binding(get: { on }, set: set)).labelsHidden() }
        }
        .frame(height: 44)
        .contentShape(Rectangle())
    }
}

struct AboutSettings: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Prefs.Key.autoUpdate) private var autoUpdate = false
    var body: some View {
        SettingsPage(symbol: "info.circle.fill", title: "Sobre", subtitle: "Versão, atualização e onde ficam os seus dados.") {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("iLand").font(Theme.display)
                    Text("versão \(Updater.current)").font(Theme.lead).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    if let r = updater.available {
                        Button("Atualizar para \(r.version)") { updater.install() }.glassButton(prominent: true).disabled(updater.busy)
                    } else {
                        Button(updater.busy ? "Procurando…" : "Procurar atualização") { updater.check() }.glassButton().disabled(updater.busy)
                    }
                    if !updater.state.isEmpty { Text(updater.state).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
                }
            }
            .padding(22)
            .glassSurface()
            GlassSection("Atualização") {
                SettingRow("Atualização automática", detail: "Desligado, o iLand só avisa e espera você clicar em Atualizar. Ligado, instala a versão nova e reabre. Os serviços ligados continuam.", divider: false) {
                    Toggle("", isOn: $autoUpdate).labelsHidden()
                }
            }
            GlassSection("Seus dados", footer: "Tudo fica neste Mac. A atualização baixa do GitHub, confere a assinatura e reabre o app. As permissões continuam valendo.") {
                SettingRow("Pasta de dados", detail: "~/Library/Application Support/iLand") {
                    Button("Abrir") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("iLand")
                        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); NSWorkspace.shared.open(dir) }
                    }
                    .glassButton()
                }
                SettingRow("Configuração inicial", detail: "Passa de novo por todos os passos.", divider: false) {
                    Button("Refazer") { Onboarding.shared.show() }.glassButton()
                }
            }
        }
    }
}
