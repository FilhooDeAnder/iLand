import SwiftUI
import AppKit

/// Assistente de configuração da primeira abertura. Todo passo pode ser pulado e refeito em Ajustes
/// (Sobre › "Configuração inicial"). Os passos usam as mesmas páginas das abas de Ajustes.
final class Onboarding {
    static let shared = Onboarding()
    private var window: NSWindow?

    func showIfNeeded() { if !Prefs.bool(Prefs.Key.onboarded) { show() } }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindow.size), styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Configurar o iLand"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)   // escura como o resto do iLand
            // depuração: ILAND_ONBOARDING=<n> abre no passo n
            let start = Int(ProcessInfo.processInfo.environment["ILAND_ONBOARDING"] ?? "") ?? 0
            w.contentView = NSHostingView(rootView: OnboardingView(done: { [weak self] in self?.finish() }, step: start))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.debugShot()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Prefs.Key.onboarded)
        window?.close()
    }
}

struct OnboardingView: View {
    let done: () -> Void
    @State var step = 0
    @State private var forward = true
    @State private var watchesServers = !Prefs.machines.isEmpty
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let count = 9
    private var isFirst: Bool { step == 0 }
    private var isLast: Bool { step == Self.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 18)
            content
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            controls.padding(.horizontal, Theme.gutter).padding(.bottom, 22)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .background(AtmosphereBackground())   // explícito: a foto de depuração (cacheDisplay) não desenha o fundo da janela
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
        .toggleStyle(.switch).tint(Theme.accent)
        .onReceive(timer) { _ in if step == 3 { trusted = AXIsProcessTrusted() } }
    }

    /// Pontos de progresso numa pílula de vidro; o passo atual vira uma cápsula com o acento.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.count, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Theme.accent : (i < step ? Theme.textSecondary : Theme.textTertiary.opacity(0.5)))
                    .frame(width: i == step ? 26 : 7, height: 7)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassSurface(cornerRadius: 16)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if !isFirst && !isLast { Button { go(-1) } label: { Label("Voltar", systemImage: "chevron.left") }.glassButton() }
            Spacer()
            if !isFirst && !isLast { Button("Pular este passo") { go(1) }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary).padding(.trailing, 6) }
            Button { isLast ? done() : go(1) } label: {
                Text(isFirst ? "Começar" : (isLast ? "Abrir o iLand" : "Continuar")).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10)
            }
            .glassButton(prominent: true)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .glassGroup()
    }

    private func go(_ d: Int) {
        forward = d > 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = min(max(step + d, 0), Self.count - 1) }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: PrivacySettings()
        case 2: ProfileSettings()
        case 3: permission
        case 4: ModelsSettings()
        case 5: ProjectsSettings().onAppear { DispatchQueue.global(qos: .utility).async { ProjectRoots.bootstrap() } }
        case 6: ClickUpSettings()
        case 7: servers
        default: finished
        }
    }

    // MARK: passos próprios

    private var welcome: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)
            NotchArt().frame(height: 70)
            VStack(spacing: 10) {
                Text("iLand").font(.system(size: 64, weight: .black, design: .rounded))
                Text("O seu Mac, no notch.").font(.system(size: 20, weight: .light)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: Theme.gap) {
                feature("thermometer.medium", "Mac à vista", "Temperatura, processos pesados e alertas sem abrir nada.")
                feature("sparkles", "Assistente", "Conhece o seu dia e usa o modelo que você escolher.")
                feature("lock.fill", "Seus dados", "Ficam neste Mac. Nenhum servidor da Loop. O próximo passo mostra tudo o que o iLand lê.")
            }
            .glassGroup(spacing: Theme.gap)
            .padding(.horizontal, Theme.gutter + 20)
            Text("Leva uns 2 minutos. Cada passo pode ser pulado e refeito depois em Ajustes.").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassIcon(symbol: symbol, size: 36)
            Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassSurface()
    }

    private var permission: some View {
        SettingsPage(symbol: "hand.raised.fill", title: "Permissão", subtitle: "Para saber em que app e projeto você está, o iLand precisa da Acessibilidade.") {
            HStack(spacing: 18) {
                GlassIcon(symbol: trusted ? "checkmark" : "lock.open", size: 64, tint: trusted ? Theme.ok : Theme.warning)
                VStack(alignment: .leading, spacing: 6) {
                    Text(trusted ? "Permissão dada" : "Falta a permissão").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(trusted ? "Tudo pronto. A página Hoje e o assistente já sabem do seu dia."
                         : "Ligue o iLand na lista. No macOS 27 o painel se chama \"Controle do Dispositivo e Acesso a Dados\".")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !trusted {
                    Button("Abrir o painel") {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .glassButton(prominent: true).controlSize(.large)
                }
            }
            .padding(22)
            .glassSurface(tint: (trusted ? Theme.ok : Theme.warning).opacity(0.08))
            Text("Sem a permissão o resto funciona, mas a página Hoje e o assistente sabem menos do seu dia.").font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    @ViewBuilder private var servers: some View {
        if watchesServers {
            MachinesSettings(monitor: MainWindow.shared.machines)
        } else {
            SettingsPage(symbol: "server.rack", title: "Servidores", subtitle: "O iLand pode vigiar CPU, memória e disco de servidores Linux por SSH.") {
                GlassSection(footer: "Sem servidores, a página Máquinas fica escondida. Dá para adicionar depois em Ajustes › Máquinas.") {
                    SettingRow("Eu acompanho servidores por SSH", divider: false) {
                        Toggle("", isOn: Binding(get: { watchesServers }, set: { v in withAnimation { watchesServers = v } })).labelsHidden()
                    }
                }
            }
        }
    }

    private var finished: some View {
        VStack(spacing: 22) {
            Spacer()
            GlassIcon(symbol: "checkmark", size: 92, tint: Theme.ok)
            Text("Tudo pronto").font(Theme.display)
            VStack(spacing: 8) {
                Text("Passe o mouse no notch para abrir o iLand.")
                Text("⌃⌥⌘Espaço abre a janela do assistente.")
                Text("Para mudar algo: clique com o botão direito no ícone do iLand na barra de menus.")
            }
            .font(Theme.lead).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Desenho do notch com as orelhas abertas, para a tela de boas-vindas.
struct NotchArt: View {
    @State private var open = false
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black)
                .frame(width: open ? 360 : 150, height: open ? 52 : 36)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
            if open {
                HStack {
                    Text("5h 42%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Spacer()
                    Text("58°").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 30).frame(width: 360, height: 52)
                .transition(.opacity)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.25)) { open = true } }
    }
}
