import AppKit
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = SystemMonitor()
    var controller: NotchController!
    private var fakeNotches: FakeNotches?
    var statusBar: StatusBarController!
    var hideWork: DispatchWorkItem?
    private var earsSwipe = SwipeTracker()
    private var signalSources: [DispatchSourceSignal] = []
    private var chartsSink: AnyCancellable?

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        DeepLink.handle(url, model: controller.tools.capture)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        signal(SIGPIPE, SIG_IGN)   // escrever num socket/pipe fechado (CLI cancelado) não pode derrubar o app
        CLI.warmUp()
        NSApp.setActivationPolicy(.accessory)
        // App sem menu não recebe ⌘V/⌘C/⌘X/⌘A/⌘Z nos campos de texto: o menu Editar (invisível no modo accessory) liga os atalhos.
        let edit = NSMenu(title: "Editar")
        for (t, s, k) in [("Desfazer", "undo:", "z"), ("Refazer", "redo:", "Z"), ("Recortar", "cut:", "x"), ("Copiar", "copy:", "c"),
                          ("Colar", "paste:", "v"), ("Selecionar tudo", "selectAll:", "a")] {
            edit.addItem(withTitle: t, action: Selector(s), keyEquivalent: k)
        }
        let main = NSMenu(), item = NSMenuItem()
        item.submenu = edit; main.addItem(item); NSApp.mainMenu = main
        controller = NotchController(monitor: monitor)
        fakeNotches = FakeNotches()
        statusBar = StatusBarController(monitor: monitor, tools: controller.tools) { [weak self] in self?.controller.setMode(.quick) }
        // O `top` (energia por app) só roda com a visão geral aberta na aba Gráficos.
        chartsSink = controller.model.$mode.combineLatest(controller.model.$tab)
            .sink { [weak self] mode, tab in
                self?.monitor.setChartsVisible(mode == .overview && tab == .charts)
                self?.monitor.setPortsVisible(mode == .overview && tab == .ports)   // `lsof`/`nettop` só na aba Portas
            }
        // Depuração: ILAND_TAB=charts (ou processes, apps, tree, ports) abre a visão geral já nessa aba.
        if let t = ProcessInfo.processInfo.environment["ILAND_TAB"], let tab = OverviewTab.allCases.first(where: { "\($0)" == t }) {
            controller.model.tab = tab
        }

        if ProcessInfo.processInfo.environment["ILAND_SETTINGS"] != nil { SettingsWindow.shared.show() }   // depuração
        Updater.shared.startDaily()
        if !Prefs.bool("projectsBootstrapped") {   // 1ª abertura: aprende os projetos pelas sessões do Claude Code e do Codex
            UserDefaults.standard.set(true, forKey: "projectsBootstrapped")
            DispatchQueue.global(qos: .utility).async { ProjectRoots.bootstrap() }
        }
        if ProcessInfo.processInfo.environment["ILAND_ONBOARDING"] != nil { Onboarding.shared.show() } else { Onboarding.shared.showIfNeeded() }

        controller.tools.activity.start()   // assistente: registro de app/projeto (local)
        MainWindow.shared.tools = controller.tools
        HotKey.register { MainWindow.shared.show(.assistant) }
        CapturePrefs.register()
        CaptureHotKeys.start(model: controller.tools.capture)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        if let s = ProcessInfo.processInfo.environment["ILAND_WINDOW"] {   // depuração: abre a janela numa seção
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainWindow.shared.show(MainWindow.Section.from(s) ?? .assistant) }
        }
        if let q = ProcessInfo.processInfo.environment["ILAND_ASK"] {   // depuração: pergunta ao assistente ao abrir
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.controller.tools.agent.send(q) }
        }
        // Cérebro, fase 1: vigia do timer do ClickUp. ILAND_TIMER_DEMO=1 mostra um cartão inventado (sem API).
        if ProcessInfo.processInfo.environment["ILAND_TIMER_DEMO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.controller.tools.timerWatch.demo() }
        } else { controller.tools.timerWatch.start(activity: controller.tools.activity) }
        if ProcessInfo.processInfo.environment["ILAND_SUMMARY_NOW"] != nil {   // depuração: gera o resumo do dia já
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.controller.tools.activity.makeSummary() }
        }
        // Máquinas: ILAND_MACHINES_DEMO=1 usa dados inventados (sem SSH), para screenshots.
        if ProcessInfo.processInfo.environment["ILAND_MACHINES_DEMO"] != nil { controller.tools.machines.loadDemo() }
        else if !Prefs.machines.isEmpty { controller.tools.machines.start() }   // sem apelidos: não consulta nada
        if Demo.on { controller.tools.tunnels.loadDemo() } else { controller.tools.tunnels.startAutos() }   // só os marcados "Ligar ao abrir" (padrão: nenhum)

        if CommandLine.arguments.contains("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { self.writeSnapshots() } }
            return
        }

        // Depuração: `kill -USR1 <pid>` abre a visão geral, `-USR2` a vista rápida, `-ALRM` as orelhas, `-HUP` recolhe.
        for (sig, mode) in [(SIGUSR1, NotchMode.overview), (SIGUSR2, .quick), (SIGALRM, .ears), (SIGHUP, .rest)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.controller.setMode(mode) }
            src.resume()
            signalSources.append(src)
        }

        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.handleMove() }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in self?.handleMove(); return e }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.handleClick() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.handleDrag() }
        NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.handleEarsScroll(e) }
    }

    /// Depuração: `iLand --snapshot` grava cada modo em PNG (sem precisar de permissão de gravação de tela).
    @MainActor private func writeSnapshots() {
        let fake = ProcSample(pid: 4242, ppid: 1, uid: getuid(), cpu: 97, rssKB: 2048, elapsed: 26_520, tty: "ttys001", path: "/usr/bin/yes")
        monitor.stats?.suspects = [Suspect(sample: fake, hint: "", chain: [Origin.Link(pid: 1, name: "sh"), Origin.Link(pid: 2, name: "claude"), Origin.Link(pid: 3, name: "Claude")], command: "yes", canKill: true)]
        var hot = AlertInput(); hot.cpuTemp = 93
        monitor.stats?.alerts = [AlertEngine.describe(.temperature, 1, hot)]
        let t0 = Date()
        monitor.stats?.history = (0..<300).map { i in
            let x = Double(i)
            return HistoryPoint(t: t0.addingTimeInterval(2 * (x - 300)), cpu: 30 + 25 * sin(x / 15), temp: 70 + 22 * sin(x / 40),
                                down: 400_000 * (1 + sin(x / 7)), up: 60_000 * (1 + cos(x / 9)), mem: 80 + 6 * sin(x / 50))
        }
        monitor.stats?.power = PowerReading(system: 13.6, battery: 5.4)
        monitor.stats?.energy = [AppEnergy(name: "mediaanalysisd", impact: 65.6), AppEnergy(name: "WindowServer", impact: 28),
                                 AppEnergy(name: "Claude", impact: 13), AppEnergy(name: "Google Chrome", impact: 10.4), AppEnergy(name: "Terminal", impact: 2.1)]
        let model = controller.model
        model.notchWidth = NotchGeometry.current()?.width ?? 208
        model.notchHeight = NotchGeometry.current()?.height ?? 37.5
        let size = NotchLayout.canvas(notchHeight: model.notchHeight)
        for (mode, name) in [(NotchMode.rest, "rest"), (.ears, "ears"), (.quick, "quick"), (.overview, "overview"), (.overview, "charts")] {
            model.mode = mode
            model.tab = name == "charts" ? .charts : .processes
            let view = NotchRoot(model: model, monitor: monitor, tools: controller.tools, actions: NotchActions(openQuick: {}, openOverview: {}))
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.35))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: DebugOut.dir.appendingPathComponent("\(name).png"))
            }
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.tools.notes.saveNow() }   // serviços continuam ligados: o próximo iLand os adota

    // Mouse sobre o notch -> orelhas. Clique no notch -> vista rápida. Fora dela, tudo recolhe.
    private func handleMove() {
        guard let g = NotchGeometry.current() else { return }
        let m = NSEvent.mouseLocation
        let near = g.hoverZone.contains(m) || controller.visibleRect.insetBy(dx: -24, dy: -24).contains(m)
        switch controller.mode {
        case .rest:
            if NotchGeometry.at(m) != nil, Prefs.bool(Prefs.Key.hoverEars) { controller.setMode(.ears) }
        case .ears:
            near || controller.model.earNotice != nil || controller.pinnedOpen ? cancelHide() : scheduleHide(after: 0.4)   // aviso de máquina: fica os 6 s
        case .quick:
            near || controller.pinnedOpen ? cancelHide() : scheduleHide(after: Prefs.quickHideDelay)
        case .overview:
            break
        }
    }

    // Arquivo arrastado até o notch: abre a prateleira para receber o drop.
    private func handleDrag() {
        guard Prefs.bool(Prefs.Key.shelfOnDrag), controller.mode == .rest || controller.mode == .ears, NotchGeometry.at(NSEvent.mouseLocation) != nil,
              NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        controller.openShelf()
    }

    // Com as orelhas abertas (a janela não pega o mouse), dedos para baixo sobre o notch entram na vista rápida.
    private func handleEarsScroll(_ e: NSEvent) {
        guard controller.mode == .ears, e.hasPreciseScrollingDeltas else { return }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) { earsSwipe.begin() }
        if e.momentumPhase != [] { return }
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        _ = earsSwipe.move(dx: sign * e.scrollingDeltaX, dy: sign * e.scrollingDeltaY)
        guard e.phase.contains(.ended) || e.phase.contains(.cancelled) else { return }
        let step = earsSwipe.end()
        // Para os lados: gira a orelha que está embaixo do mouse; em cima do notch, as duas.
        if step != 0, let g = NotchGeometry.current(), controller.visibleRect.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) {
            let x = NSEvent.mouseLocation.x
            controller.rollEars(x < g.centerX - g.width / 2 ? .left : x > g.centerX + g.width / 2 ? .right : nil, step: step, user: true)
        }
        if earsSwipe.lastWasDown, controller.visibleRect.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) { controller.setMode(.quick) }
    }

    private func handleClick() {
        guard let g = NotchGeometry.current() else { return }
        let m = NSEvent.mouseLocation
        switch controller.mode {
        case .rest, .ears:
            if (controller.mode == .rest ? NotchGeometry.at(m) != nil : g.hoverZone.contains(m)) || controller.visibleRect.contains(m) { controller.setMode(.quick) }
        case .quick, .overview:
            if !controller.visibleRect.contains(m) { controller.setMode(.rest) }
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        guard hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            if self.controller.pinnedOpen { return }
            // O mouse pode ter voltado para cima da nossa janela, que não gera evento global.
            let m = NSEvent.mouseLocation
            if let g = NotchGeometry.current(), g.hoverZone.contains(m) || self.controller.visibleRect.insetBy(dx: -24, dy: -24).contains(m) { return }
            if self.controller.mode != .overview { self.controller.setMode(.rest) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay * NotchLayout.slow, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }
}

/// Saída de depuração (--snapshot, ILAND_DEBUG): ILAND_SHOTS ou uma pasta privada (0700) no diretório temporário do usuário.
enum DebugOut {
    static var dir: URL {
        let p = ProcessInfo.processInfo.environment["ILAND_SHOTS"] ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("iland-debug")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return URL(fileURLWithPath: p)
    }
}
