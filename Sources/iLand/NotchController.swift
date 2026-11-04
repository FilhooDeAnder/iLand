import AppKit
import SwiftUI
import Combine

/// Aceita o clique mesmo quando a janela ainda não é a principal (senão o 1º clique só dá foco).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onScroll: ((NSEvent) -> Bool)?   // true = o gesto é nosso (swipe horizontal): não passa para a rolagem da lista
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) {
        if onScroll?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onArrow: ((Int) -> Void)?   // -1 esquerda, +1 direita
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onArrow?(-1)
        case 124: onArrow?(1)
        default: super.keyDown(with: event)
        }
    }
}

/// Dono da janela única do notch. A janela tem sempre o tamanho exato do que está desenhado,
/// para não bloquear cliques no resto da tela.
final class NotchController {
    let model = NotchUIModel()
    let tools = ToolsModel()
    private var swipe = SwipeTracker()
    private var backAllowed = false
    private var downAllowed = false
    private var dragFrameSet = false   // a janela já foi aberta para a página vizinha durante este arrasto
    private var swipeOwned = false   // o gesto atual (e a inércia dele) é nosso
    private var pageSink: AnyCancellable?
    private var modeSink: AnyCancellable?
    private let monitor: SystemMonitor
    private let panel: NotchPanel
    private var statsSink: AnyCancellable?
    private var hideWork: DispatchWorkItem?
    private var host: FirstMouseHostingView<NotchRoot>!
    private var resizeGen = 0
    private var machinesSink: AnyCancellable?
    private var resumeSink: AnyCancellable?
    private var summarySink: AnyCancellable?
    private var timerSink: AnyCancellable?
    private var noticeWork: DispatchWorkItem?
    private var earTimer: Timer?
    private var earSinks: [AnyCancellable] = []

    var mode: NotchMode { model.mode }
    /// A página do Claude fica aberta enquanto você digita: sem fechar sozinha quando o mouse sai.
    var pinnedOpen: Bool {
        if model.mode == .ears { return ProcessInfo.processInfo.environment["ILAND_PIN"] != nil }   // depuração: prints das orelhas
        return model.mode == .quick && (ProcessInfo.processInfo.environment["ILAND_PIN"] != nil   // depuração
            || model.quickPage == QuickPage.claude.rawValue || model.quickPage == QuickPage.notes.rawValue
            || (model.quickPage == QuickPage.capture.rawValue && tools.capture.editingConfig)
            || (model.quickPage == QuickPage.clipboard.rawValue && !tools.clipboard.query.isEmpty)
            || (model.quickPage == QuickPage.machines.rawValue && tools.machines.holdOpen))
    }

    /// O relógio do volume só roda com a página Som à vista.
    private func updateSoundClock() { tools.sound.setActive(model.mode == .quick && model.quickPage == QuickPage.sound.rawValue) }

    /// Arquivo sendo arrastado até o notch: abre a prateleira.
    func openShelf() {
        guard !Prefs.hidden.contains(QuickPage.shelf.rawValue) else { return }
        model.quickPage = QuickPage.shelf.rawValue
        setMode(.quick)
    }
    /// Retângulo realmente desenhado (a janela pode ser maior que a peça durante a animação).
    var visibleRect: NSRect {
        guard panel.isVisible, let g = NotchGeometry.current() else { return .zero }
        let L = NotchLayout.self
        switch model.mode {
        case .rest:
            return .zero
        case .ears:
            let w = g.width + 2 * L.wing + 2 * L.ear
            return NSRect(x: g.centerX - w / 2, y: g.top - g.height, width: w, height: g.height)
        case .quick, .overview:
            return panel.frame
        }
    }

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.onEscape = { [weak self] in self?.setMode(.rest) }
        NotificationCenter.default.addObserver(forName: .ilandCollapse, object: nil, queue: .main) { [weak self] _ in self?.setMode(.rest) }

        let root = NotchRoot(model: model, monitor: monitor, tools: tools,
                             actions: NotchActions(openQuick: { [weak self] in self?.setMode(.quick) },
                                                   openOverview: { [weak self] in self?.setMode(.overview) }))
        // O desenho (host) fica sempre no mesmo lugar da tela; a janela é só o recorte que deixa clicar fora.
        host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        tools.clipboard.start()
        if ProcessInfo.processInfo.environment["ILAND_CAPTURE_CFG"] != nil { tools.capture.editingConfig = true }   // depuração
        if let d = ProcessInfo.processInfo.environment["ILAND_DEMO_TOOLS"] {   // depuração: 1 = os dois, pomo, caf
            if d != "caf" { tools.togglePomodoro() }
            if d != "pomo" { tools.turnOnCaffeine(minutes: 30) }
        }   // depuração
        // depuração: ILAND_PAGE=tools|shelf|claude abre a vista rápida já nessa página
        if let name = ProcessInfo.processInfo.environment["ILAND_PAGE"], let i = ["sound": 1, "tools": 2, "shortcuts": 3, "capture": 4, "clipboard": 5, "shelf": 6, "notes": 7, "claude": 8, "machines": 9, "today": 10, "tunnels": 11, "playing": 12][name] { model.quickPage = i }
        // depuração: ILAND_AUTOPAGE=N vai e volta entre as páginas Resumo (0) e N a cada 10 s, para filmar a troca de alturas
        if let n = ProcessInfo.processInfo.environment["ILAND_AUTOPAGE"].flatMap(Int.init) {
            var up = true
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, self.model.mode == .quick else { return }
                self.model.stepPage(up ? n - self.model.quickPage : -self.model.quickPage); up.toggle()
            }
        }   // depuração
        if let d = ProcessInfo.processInfo.environment["ILAND_DRAG"].flatMap(Double.init) { model.dragX = CGFloat(d) }   // depuração: página arrastada
        host.onScroll = { [weak self] e in self?.handleScroll(e) ?? false }
        panel.onArrow = { [weak self] d in
            guard let self, self.model.mode == .overview else { return }
            self.model.stepTab(d)
        }
        let container = NSView()
        container.addSubview(host)
        panel.contentView = container

        modeSink = model.$mode.sink { [weak self] m in
            if m != .ears { self?.model.earsRolled = false }
            DispatchQueue.main.async { self?.updateSoundClock(); self?.updateEarTimer() }
        }
        // Ajustes das orelhas mudaram: as catracas usam a lista nova na hora.
        earSinks.append(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            guard let self else { return }
            let c = EarConfig.decode(Prefs.string(Prefs.Key.earDials))
            if c != self.model.dials.config { self.model.dials.config = c; self.updateEarTimer() }
        })
        // Timer começou a rodar (ou voltou da pausa) com "passar à frente": a catraca dele vai para ele.
        earSinks.append(tools.$pomodoro.combineLatest(tools.$stopwatch).map { $0.isRunning || $1.isRunning }.removeDuplicates().dropFirst()
            .filter { $0 }.sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, Prefs.bool(Prefs.Key.timerFront) else { return }
                    self.model.dials.bringTimer(); self.saveEarPos()
                }
            })

        // Trocar de página muda a altura da vista rápida: a janela acompanha (cresce na hora, encolhe depois da animação).
        pageSink = model.$quickPage.dropFirst().sink { [weak self] page in
            guard let self else { return }
            DispatchQueue.main.async { self.updateSoundClock() }   // @Published avisa antes de gravar: lê o valor novo no próximo ciclo
            // `model.quickPage` ainda tem o valor ANTIGO aqui: o frame precisa usar a página nova, senão a janela
            // fica pequena e corta a forma que cresce (e só "pula" no próximo ciclo de estatísticas).
            guard self.model.mode == .quick || self.model.mode == .ears, let f = self.frame(for: .quick, page: page) else { return }
            self.resize(to: f)
        }

        // A vista rápida cresce ou encolhe conforme o número de suspeitos.
        statsSink = monitor.$stats.sink { [weak self] _ in
            guard let self, self.model.mode != .rest, self.model.mode != .overview, let f = self.frame(for: .quick) else { return }
            self.resize(to: f)
        }

        // Máquinas: amarelo abre as orelhas por 6 s com "<apelido> ▲"; vermelho abre a página Máquinas e segura aberta.
        machinesSink = tools.machines.notices.sink { [weak self] n in self?.show(n) }
        // Onde parei: voltou a um projeto depois de 1 h -> "↩ projeto" na orelha; clicar abre a página Hoje com as pistas.
        resumeSink = tools.activity.resumes.sink { [weak self] info in
            self?.flashEars("↩ \(ProjectResolver.display(info.project))", page: .today, seconds: 8)
        }
        // Resumo do dia pronto (feito no bloqueio das 17h): avisa ao desbloquear; clicar abre a página Hoje no resumo.
        summarySink = tools.activity.summaries.sink { [weak self] in self?.flashEars("resumo do dia", page: .today, seconds: 10) }
        // Vigia do timer: "⏱ timer?" na orelha; clicar abre a página Hoje com o cartão.
        timerSink = tools.timerWatch.cards.sink { [weak self] _ in self?.flashEars("⏱ timer?", page: .today, seconds: 12) }
    }

    private func show(_ n: MachineNotice) {
        if n.level == .crit {
            tools.machines.focus = n.alias
            tools.machines.holdOpen = true
            model.selectPage(QuickPage.machines.rawValue)   // escondida nos Ajustes: cai no Resumo
            setMode(.quick)
            return
        }
        flashEars("\(n.alias) ▲", page: .machines, seconds: 6)
    }

    /// Gira as orelhas: `side` nil = as duas (rolar no notch ou o giro automático). `user` = a pessoa rolou (o giro automático para).
    func rollEars(_ side: EarSide?, step: Int, user: Bool) {
        let d = EarData(stats: monitor.stats, tools: tools, machines: tools.machines, source: Prefs.string(Prefs.Key.earsSource))
        model.earStep = step
        withAnimation(.easeInOut(duration: 0.25 * NotchLayout.slow)) { model.dials.roll(side, step: step, has: d.has) }
        model.earTick += 1
        saveEarPos()
        if user, !model.earsRolled { model.earsRolled = true; updateEarTimer() }
    }

    /// Clique na orelha que mostra a música: a vista rápida abre na página "Tocando".
    func pageForEar(_ side: EarSide) {
        let d = EarData(stats: monitor.stats, tools: tools, machines: tools.machines, source: Prefs.string(Prefs.Key.earsSource))
        guard side == .left || model.earNotice == nil, model.dials.shown(side, has: d.has) == .media,
              !Prefs.hidden.contains(QuickPage.playing.rawValue) else { return }
        model.quickPage = QuickPage.playing.rawValue
    }

    private func saveEarPos() {
        UserDefaults.standard.set(model.dials.current.map { $0?.rawValue ?? "" }.joined(separator: ","), forKey: Prefs.Key.earDialPos)
    }

    /// Giro automático: só com as orelhas abertas, no modo "a cada N s" e até a pessoa rolar.
    private func updateEarTimer() {
        earTimer?.invalidate(); earTimer = nil
        let n = model.dials.config.autoSeconds
        guard model.mode == .ears, n > 0, !model.earsRolled else { return }
        model.earTick += 1
        earTimer = Timer.scheduledTimer(withTimeInterval: Double(n) * NotchLayout.slow, repeats: true) { [weak self] _ in
            self?.rollEars(nil, step: 1, user: false)
        }
    }

    /// Aviso curto na orelha direita; clicar abre a vista rápida em `page`. Com a vista rápida aberta, não interrompe.
    private func flashEars(_ text: String, page: QuickPage, seconds: Double) {
        guard model.mode == .rest || model.mode == .ears else { return }
        noticeWork?.cancel()
        if !Prefs.hidden.contains(page.rawValue) { model.quickPage = page.rawValue }
        model.earNotice = text
        setMode(.ears)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.earNotice = nil
            if self.model.mode == .ears { self.setMode(.rest) }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * NotchLayout.slow, execute: work)
    }

    /// Uma forma só (NotchBlobView): ir direto de qualquer estado a qualquer outro não corta a peça em duas.
    func setMode(_ new: NotchMode) { apply(new) }

    private func apply(_ new: NotchMode) {
        guard new != model.mode else { return }
        if model.mode == .rest { NotchGeometry.follow(NSEvent.mouseLocation) }   // abre na tela do mouse
        guard let g = NotchGeometry.current() else { return }
        hideWork?.cancel()
        // Ainda sumindo em outra tela: tira de lá antes, senão a janela vira a união das duas telas.
        // Ainda fechando a vista rápida (janela alta): reabrir daqui faria as orelhas crescerem enquanto a altura ainda desce.
        // Recomeça do repouso, como se a janela já tivesse sumido.
        if panel.isVisible, model.mode == .rest, !g.screen.frame.contains(panel.frame) || panel.frame.height > g.height + 1 {
            panel.orderOut(nil)
            model.epoch += 1
        }
        monitor.setActive(new == .quick || new == .overview)
        tools.setVisible(new != .rest)
        let anim = Animation.spring(response: 0.38 * NotchLayout.slow, dampingFraction: 1)   // sem quicar
        if new == .rest {
            tools.machines.holdOpen = false   // fechou (clique fora, Esc): o vermelho já foi visto
            resizeGen += 1
            withAnimation(anim) { model.mode = .rest }
            tools.setVisible(false)
            // Quase dentro do notch: some num fade curto, em vez de deixar a faixa preta embaixo dele até a janela sair.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28 * NotchLayout.slow) { [weak self] in
                guard let self, self.model.mode == .rest else { return }
                withAnimation(.easeOut(duration: 0.14 * NotchLayout.slow)) { self.model.faded = true }
            }
            let work = DispatchWorkItem { [weak self] in
                if self?.model.mode == .rest { self?.panel.orderOut(nil) }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 * NotchLayout.slow, execute: work)
            return
        }
        model.faded = false
        model.notchWidth = g.width
        model.notchHeight = g.height
        guard let f = frame(for: new) else { return }
        let wasVisible = panel.isVisible
        resize(to: f)
        // Orelhas não capturam o mouse (o clique no notch vem do monitor global); vista rápida e visão geral capturam.
        panel.ignoresMouseEvents = (new == .ears)
        if ProcessInfo.processInfo.environment["ILAND_DEBUG"] != nil {
            NSLog("iLand frame pedido=%@ real=%@ content=%@ safe=%@", NSStringFromRect(f), NSStringFromRect(panel.frame), NSStringFromRect(panel.contentView?.frame ?? .zero), String(describing: panel.contentView?.safeAreaInsets))
        }
        if ProcessInfo.processInfo.environment["ILAND_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let v = self?.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: DebugOut.dir.appendingPathComponent("win.png"))
                NSLog("iLand dump: frame=%@ contentView=%@ windowTop=%@", NSStringFromRect(self!.panel.frame), NSStringFromRect(v.frame), String(describing: self!.panel.contentLayoutRect))
            }
        }
        if !wasVisible { panel.orderFrontRegardless() }
        if new == .overview { panel.makeKey() }
        // Janela nova: deixa o SwiftUI desenhar o estado recolhido antes de animar o crescimento.
        if wasVisible { withAnimation(anim) { model.mode = new } }
        else { DispatchQueue.main.async { withAnimation(anim) { self.model.mode = new } } }
    }

    /// Arrastar com 2 dedos para os lados: troca a página da vista rápida (ela acompanha o dedo) ou a aba da visão geral.
    private func handleScroll(_ e: NSEvent) -> Bool {
        guard e.hasPreciseScrollingDeltas, model.mode == .quick || model.mode == .overview else { return false }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            swipe.begin(); swipeOwned = false
            // Dedos para cima voltam da visão geral para a vista rápida. Na aba Portas a lista rola: só vale começando acima dela.
            let fromTop = panel.frame.maxY - NSEvent.mouseLocation.y
            backAllowed = model.tab != .ports || fromTop - (model.notchHeight - NotchLayout.fillet) < NotchLayout.overviewListTop
            // Dedos para baixo entram no próximo nível. Nas páginas com lista rolável só vale começando no cabeçalho.
            let scrolls = [QuickPage.shelf, .claude, .clipboard, .notes, .machines, .tunnels].contains { $0.rawValue == model.quickPage }
            downAllowed = !scrolls || fromTop < model.notchHeight + 6
        }
        // Inércia depois do gesto: é nossa se o gesto era nosso.
        if e.momentumPhase != [] { return swipeOwned }
        // Deslocamento do dedo (direita e para baixo positivos), qualquer que seja o "rolagem natural" do sistema.
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        let ours = swipe.move(dx: sign * e.scrollingDeltaX, dy: sign * e.scrollingDeltaY)
        if ours {
            swipeOwned = true
            if model.mode == .quick {
                // A página vizinha pode ser mais alta: a janela já cresce no começo do arrasto (volta ao normal no fim).
                if !dragFrameSet, let f = frame(for: .quick, page: model.quickPage, includeNeighbors: true) { dragFrameSet = true; resize(to: f) }
                model.dragX = swipe.offset
            }
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            let d = swipe.end()
            let hadDragFrame = dragFrameSet
            dragFrameSet = false
            if model.mode == .quick {
                if hadDragFrame, d == 0, let f = frame(for: .quick) { resize(to: f) }
                if d != 0 { model.stepPage(d) } else { withAnimation(.spring(response: 0.3, dampingFraction: 1)) { model.dragX = 0 } }
                if d == 0, swipe.lastWasDown, downAllowed { setMode(.overview) }
                else if d == 0, swipe.lastWasUp { setMode(.ears) }
            } else if d != 0 {
                model.stepTab(d)
            } else if swipe.lastWasUp, backAllowed {
                setMode(.quick)
            }
        }
        return ours
    }

    /// Cresce na hora; o que precisa encolher espera a animação (janela = união do atual com o novo até lá),
    /// senão a janela corta o desenho que ainda está mudando.
    private func resize(to f: NSRect) {
        resizeGen += 1
        let cur = panel.frame
        if !panel.isVisible || f.contains(cur) { place(f); return }
        if cur == f { return }
        let u = cur.union(f)
        if u != cur { place(u) }
        let gen = resizeGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * NotchLayout.slow) { [weak self] in
            guard let self, self.resizeGen == gen, self.panel.isVisible, self.model.mode != .rest else { return }
            self.place(f)
        }
    }

    /// Troca o frame da janela e compensa a posição do desenho no mesmo ciclo: na tela nada se mexe.
    private func place(_ frame: NSRect) {
        guard let g = NotchGeometry.current() else { return }
        // Pixel inteiro: o macOS arredonda o frame da janela; se a compensação do desenho usar o valor fracionário
        // (ex.: y=986,5), o desenho desce 0,5 pt e sobra uma linha de 1 pixel azul no topo.
        let f = frame.integral
        let c = NotchLayout.canvas(notchHeight: g.height)
        panel.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = NSRect(x: g.centerX - c.width / 2 - f.minX, y: g.top - c.height - f.minY, width: c.width, height: c.height)
        panel.setFrame(f, display: true)
        CATransaction.commit()
    }

    private func frame(for mode: NotchMode, page: Int? = nil, includeNeighbors: Bool = false) -> NSRect? {
        guard let g = NotchGeometry.current() else { return nil }
        let L = NotchLayout.self
        switch mode {
        case .rest:
            return nil
        case .ears, .quick:
            let cur = page ?? model.quickPage
            let pages = includeNeighbors ? [model.neighbor(cur, -1), cur, model.neighbor(cur, 1)].compactMap { $0 } : [cur]
            let h = pages.map { L.pageHeight($0, notchHeight: g.height, suspects: min(3, monitor.stats?.suspects.count ?? 0), alerts: min(2, monitor.stats?.alerts.count ?? 0)) }.max() ?? 0
            let w = L.quickWidth + 2 * L.ear
            return NSRect(x: g.centerX - w / 2, y: g.top - h, width: w, height: h)
        case .overview:
            // Desde o topo da tela: o preto cobre o notch inteiro e o gesto em cima dele chega ao painel.
            let h = g.height + L.overviewHeight
            return NSRect(x: g.centerX - L.overviewWidth / 2, y: g.top - h, width: L.overviewWidth, height: h)
        }
    }
}
