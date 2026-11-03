import SwiftUI

/// Orelhas, vista rápida e visão geral são UMA forma (IslandShape) que cresce de trás do notch: os lados deslizam para fora
/// e o fundo desce, juntos, na mesma mola. Nada de zoom. Tudo que está atrás do notch físico fica invisível,
/// então em repouso a forma fica inteira dentro dele.
/// O texto anda com a borda da forma ou só aparece quando a forma já chegou no lugar (nunca é cortado visível).
struct NotchBlobView: View {
    @ObservedObject var model: NotchUIModel
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var tools: ToolsModel
    @ObservedObject var machines: MachinesMonitor
    @ObservedObject var agent: AgentController
    let actions: NotchActions
    @AppStorage(Prefs.Key.earsSource) private var earsSource = "claude"
    private var showUsage: Bool { earsSource != "none" }

    var body: some View {
        let L = NotchLayout.self
        let nw = model.notchWidth, nh = model.notchHeight
        let s = monitor.stats
        let suspects = Array((s?.suspects ?? []).prefix(3))
        let alerts = Array((s?.alerts ?? []).prefix(2))
        let issues = (s?.suspects.count ?? 0) + (s?.alerts.count ?? 0) + machines.issueCount
        let W = L.quickWidth + 2 * L.ear                      // topo da vista rápida
        // Arrastando para a página vizinha, a forma já vai crescendo/encolhendo até a altura dela (senão os cartões
        // da página mais alta passam do preto enquanto o dedo está no meio).
        let page = model.quickPage
        let h0 = L.pageHeight(page, notchHeight: nh, suspects: suspects.count, alerts: alerts.count)
        let drag = model.resistedDrag
        let H: CGFloat
        if drag != 0, let nb = model.neighbor(page, drag < 0 ? 1 : -1) {
            H = h0 + (L.pageHeight(nb, notchHeight: nh, suspects: suspects.count, alerts: alerts.count) - h0) * min(abs(drag) / L.quickWidth, 1)
        } else { H = h0 }
        let C = L.canvas(notchHeight: nh), dx = (C.width - W) / 2
        let OH = nh + L.overviewHeight                        // fundo da visão geral
        let restW = nw - 8, earsW = nw + 2 * (L.wing + L.ear)
        // Repouso: dentro do notch físico, longe dos cantos arredondados dele.
        // Visão geral: o topo volta à largura do notch e o corpo cresce abaixo dele.
        let (tw, bw, th): (CGFloat, CGFloat, CGFloat) = switch model.mode {
        case .rest: (restW, restW - 2 * L.ear, nh)   // mesma altura das orelhas: abrir e fechar só mexe na largura
        case .ears: (earsW, earsW - 2 * L.ear, nh)
        case .quick: (W, W - 2 * L.ear, H)
        case .overview: (nw, C.width, OH)
        }
        let isEars = model.mode == .ears, isQuick = model.mode == .quick, isOverview = model.mode == .overview
        let earFade = Animation.easeOut(duration: 0.12 * L.slow)   // texto das orelhas só existe no modo orelhas

        // `H` também é animado (Hi): numa troca de página ele acompanha a forma e o conteúdo não some; na entrada ele fica parado.
        return IslandFrame(topWidth: tw, bodyWidth: bw, height: th, pageHeight: H) { tw, bw, th, H in
            let side = (W - tw) / 2 + L.ear                   // x do lado reto esquerdo (na largura W)
            // 0 escondida no notch, 1 com as orelhas abertas.
            let open = smooth((tw - restW) / (earsW - restW))
            // Chega a 1 só nos últimos 16 pt do caminho: margem do conteúdo à borda (botão a 16 pt do fundo, texto a 18 do lado).
            // Medido contra a altura animada da página: trocar para uma página maior ou menor não apaga o conteúdo.
            let ready = smooth(1 - max((W - tw) / 2, H - th) / 16)
            // Idem para a visão geral: conteúdo a 18 pt dos lados e 14 do fundo.
            let overviewReady = smooth(1 - max((C.width - bw) / 2, OH - th) / 12)
            let ph = min(max((th - nh) / (H - nh), 0), 1)
            let shape = IslandShape(topWidth: tw, bodyWidth: bw, height: th, radius: L.ear + L.ear * ph, shoulder: nh)

            ZStack(alignment: .topLeading) {
                shape.fill(Color.black)

                ZStack(alignment: .topLeading) {
                    // Orelhas: uso do Claude, 5 h à esquerda e 7 dias à direita, presos à borda (saem de trás do notch com ela).
                    let u = s?.usage, stale = u?.isStale() ?? false
                    Group {
                        if tools.hasTimer { EarTimerLabel(tools: tools, ticker: tools.ticker) }
                        else if showUsage { usageLabel("5h", ClaudeUsage.percent(u?.fiveHour), stale: stale) }
                    }
                        .frame(width: L.wing, height: nh)
                        .opacity(isEars ? 1 : 0).animation(earFade, value: isEars).opacity(open)
                        .offset(x: side)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let n = model.earNotice {
                            Text(n).font(.system(size: 11, weight: .semibold)).foregroundColor(n.contains("▲") ? .orange : .white).lineLimit(1)
                        } else if showUsage { usageLabel("7d", ClaudeUsage.percent(u?.sevenDay), stale: stale) }
                        if agent.orb == .thinking || agent.orb == .attention { OrbView(state: agent.orb, size: 6) }   // presença do assistente
                        // Suspeitos + alertas ativos, discreto, só enquanto houver.
                        if issues > 0 {
                            Text("▲\(issues)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundColor(.orange)
                        }
                    }
                    .lineLimit(1).fixedSize()
                    .frame(width: L.wing, height: nh)
                    .opacity(isEars ? 1 : 0).animation(earFade, value: isEars).opacity(open)
                    .offset(x: W - side - L.wing)

                    // Cabeçalho da vista rápida, também preso às bordas.
                    HStack(spacing: 10) {
                        tempLabel(Fmt.temp(s?.cpuTemp ?? 0), "CPU")
                        tempLabel(Fmt.temp(s?.gpuTemp ?? 0), "GPU")
                    }
                    .frame(height: nh)
                    .offset(x: side + 18)
                    .opacity(ready)
                    Group {
                        if issues == 0 { Text("tudo certo").foregroundColor(secondary) }
                        else { Text(Fmt.issues(suspects: s?.suspects.count ?? 0, alerts: s?.alerts.count ?? 0, machines: machines.issueCount)).foregroundColor(.orange) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: max(0, W - 2 * side - 36), height: nh, alignment: .trailing)
                    .offset(x: side + 18)
                    .opacity(ready)

                    // Corpo: parado na posição final; a forma o revela e ele aparece quando ela chega.
                    // Cada página tem a própria altura final e não muda durante a animação; a forma é que recorta.
                    QuickPages(model: model, monitor: monitor, tools: tools, suspects: suspects, alerts: alerts, onOverview: actions.openOverview)
                        .frame(width: L.quickWidth, height: L.maxQuickHeight(notchHeight: nh) - nh + L.ear, alignment: .top)
                        // Embaixo o conteúdo some suavemente antes da borda da forma (nunca um cartão cortado ao meio).
                        .mask(alignment: .top) {
                            let mh = max(1, th - nh + L.ear - L.navBar - 6)
                            LinearGradient(stops: [.init(color: .black, location: max(0, 1 - 12 / mh)), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(width: L.quickWidth, height: mh)
                        }
                        .offset(x: L.ear, y: nh - L.ear + L.navBar + 6)   // abaixo da barra de ícones
                        .opacity(ready)
                        .allowsHitTesting(isQuick)

                    // Barra de ícones: passar o mouse (ou clicar) vai direto à página (sem arrastar até o fim).
                    HStack(spacing: 2) {
                        ForEach(model.visiblePages.compactMap(QuickPage.init(rawValue:)), id: \.rawValue) { p in
                            let on = p.rawValue == model.quickPage
                            Button { model.selectPage(p.rawValue) } label: {
                                Image(systemName: p.symbol).font(.system(size: 11, weight: .medium))
                                    .foregroundColor(on ? .white : secondary)
                                    .frame(width: 30, height: 20)
                                    .background(Capsule().fill(Color.white.opacity(on ? 0.2 : 0)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain).help(p.title)
                            .onHover { if $0, !on { model.selectPage(p.rawValue) } }
                        }
                        Rectangle().fill(secondary.opacity(0.4)).frame(width: 1, height: 12).padding(.horizontal, 4)
                        // Ajustes já na aba da página atual (ex.: Máquinas abre o cadastro de máquinas).
                        let page = QuickPage(rawValue: model.quickPage) ?? .summary
                        Button { SettingsWindow.shared.show(page.settingsTab) } label: {
                            Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .medium))
                                .foregroundColor(secondary).frame(width: 30, height: 20).contentShape(Capsule())
                        }
                        .buttonStyle(.plain).help("Ajustes · \(page.settingsTab.rawValue)")
                    }
                    .frame(width: W)
                    .offset(y: nh + 2)   // logo abaixo do cabeçalho: fica no mesmo lugar em todas as páginas
                    .opacity(ready)
                    .allowsHitTesting(isQuick)
                }
                .frame(width: W, height: L.canvas(notchHeight: nh).height, alignment: .topLeading)
                .offset(x: dx)

                // Visão geral: parada na posição final, aparece quando a forma termina de crescer.
                OverviewView(model: model, monitor: monitor)
                    .offset(y: nh - L.fillet)
                    .opacity(overviewReady)
                    .allowsHitTesting(isOverview)
            }
            .frame(width: C.width, height: C.height, alignment: .topLeading)
            .clipShape(shape)
        }
        // Suspeito novo/resolvido muda a altura do Resumo sem passar por withAnimation: anima igual às trocas de página.
        .animation(model.dragX == 0 ? .spring(response: 0.38 * L.slow, dampingFraction: 1) : nil, value: H)
        .frame(width: C.width, height: C.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func smooth(_ x: CGFloat) -> Double {
        let t = Double(min(max(x, 0), 1))
        return t * t * (3 - 2 * t)
    }

    /// "5h 42%": rótulo pequeno cinza + número. Branco; laranja a partir de 80%; vermelho a partir de 95%. Defasado = apagado.
    private func usageLabel(_ label: String, _ pct: Int?, stale: Bool) -> some View {
        let color: Color = switch pct ?? 0 { case 95...: .red; case 80...: .orange; default: .white }
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundColor(secondary)
            Text(pct.map { "\($0)%" } ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundColor(color).opacity(stale ? 0.4 : 1)
        }
        .lineLimit(1).fixedSize()
    }

    private func tempLabel(_ t: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(t).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundColor(.white)
            Text(label).font(.system(size: 10)).foregroundColor(secondary)
        }
    }
}

/// Recebe o tamanho-alvo da forma e entrega ao conteúdo o tamanho interpolado de cada quadro,
/// para forma, recorte e opacidade do texto saírem do mesmo número (sempre sincronizados).
struct IslandFrame<Content: View>: View, Animatable {
    var topWidth: CGFloat
    var bodyWidth: CGFloat
    var height: CGFloat
    var pageHeight: CGFloat
    @ViewBuilder let content: (CGFloat, CGFloat, CGFloat, CGFloat) -> Content

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(topWidth, bodyWidth), .init(height, pageHeight)) }
        set {
            topWidth = newValue.first.first; bodyWidth = newValue.first.second
            height = newValue.second.first; pageHeight = newValue.second.second
        }
    }

    var body: some View { content(topWidth, bodyWidth, height, pageHeight) }
}

/// Conteúdo do corpo da vista rápida: lista de suspeitos e o botão da visão geral.
struct QuickBody: View {
    @ObservedObject var model: NotchUIModel
    @ObservedObject var monitor: SystemMonitor
    let suspects: [Suspect]
    var alerts: [Alert] = []
    let onOverview: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(alerts) { AlertRow(alert: $0, monitor: monitor) }
            if suspects.isEmpty && alerts.isEmpty {
                Text("Nenhum processo usando CPU demais.")
                    .font(.system(size: 12)).foregroundColor(secondary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            }
            ForEach(suspects) { SuspectRow(suspect: $0, monitor: monitor) }
            Button("Abrir visão geral", action: onOverview)
                .buttonStyle(CapsuleStyle(fill: true))
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, NotchLayout.ear)
        .padding(.bottom, 16)
    }
}

/// Páginas da vista rápida lado a lado; a de baixo acompanha o dedo e desliza (sem escala).
struct QuickPages: View {
    @ObservedObject var model: NotchUIModel
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var tools: ToolsModel
    let suspects: [Suspect]
    var alerts: [Alert] = []
    let onOverview: () -> Void

    var body: some View {
        let w = NotchLayout.quickWidth
        let visible = model.visiblePages
        let index = visible.firstIndex(of: model.quickPage) ?? 0
        // .top: a página mais baixa não pode descer para o centro da mais alta.
        // Só a página atual e as vizinhas existem de verdade (as outras são vazias): menos memória e menos redesenho.
        HStack(alignment: .top, spacing: 0) {
            ForEach(visible, id: \.self) { raw in
                if let p = QuickPage(rawValue: raw) { page(p, w, near: abs((visible.firstIndex(of: raw) ?? 0) - index) <= 1) { content(p) } }
            }
        }
        .offset(x: -CGFloat(index) * w + model.resistedDrag)
        .frame(width: w, alignment: .topLeading)
        .clipped()   // só para as páginas vizinhas não vazarem para os lados; a forma recorta embaixo
    }

    @ViewBuilder private func content(_ p: QuickPage) -> some View {
        switch p {
        case .summary: QuickBody(model: model, monitor: monitor, suspects: suspects, alerts: alerts, onOverview: onOverview)
        case .sound: SoundPage(sound: tools.sound)
        case .tools: ToolsPage(tools: tools)
        case .shortcuts: ShortcutsPage(s: tools.shortcuts)
        case .capture: CapturePage(cap: tools.capture)
        case .clipboard: ClipboardPage(clip: tools.clipboard)
        case .shelf: ShelfPage(shelf: tools.shelf)
        case .notes: NotesPage(notes: tools.notes)
        case .claude: ClaudePage(agent: tools.agent, brain: tools.brain)
        case .machines: MachinesPage(machines: tools.machines)
        case .today: TodayPage(activity: tools.activity, watch: tools.timerWatch)
        case .tunnels: TunnelsPage(tunnels: tools.tunnels)
        }
    }

    @ViewBuilder private func page<Content: View>(_ p: QuickPage, _ w: CGFloat, near: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        let L = NotchLayout.self, nh = model.notchHeight
        // Altura final da própria página (sem depender da página atual): ela não estica nem encolhe durante a troca.
        let h = L.pageHeight(p.rawValue, notchHeight: nh, suspects: suspects.count, alerts: alerts.count) - nh + L.ear
        if near || model.pageSpan?.contains(p.rawValue) == true { content().frame(width: w, height: h, alignment: .top) }
        else { Color.clear.frame(width: w, height: 1) }
    }
}

/// Contagem do pomodoro/cronômetro na orelha: rótulo pequeno + tempo. Só esta view redesenha a cada segundo.
struct EarTimerLabel: View {
    @ObservedObject var tools: ToolsModel
    @ObservedObject var ticker: Ticker

    var body: some View {
        if let t = tools.earText {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(t.label).font(.system(size: 10)).foregroundColor(secondary)
                Text(t.value).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(.white)
            }
            .lineLimit(1).fixedSize()
        }
    }
}
