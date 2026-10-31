import AppKit
import Combine
import Carbon.HIToolbox

/// Registra em que app e projeto a pessoa está (assistente, fase 1). Nada sai do Mac: só o log local em
/// ~/Library/Application Support/iLand/activity. A Acessibilidade roda numa fila própria com timeout de 1 s
/// (um app travado não congela o notch). Privado (PrivacyGate) guarda só app, tempo e projeto vindo de caminho.
/// Fase 2: ao voltar a um projeto depois de 1 h, junta as pistas do "onde parei" (Resume) e avisa.
final class ActivitySensor: ObservableObject {
    @Published private(set) var today: [ActivitySummary.Row] = []
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var resume: Resume.Info?        // pistas do último "onde parei" (cartão na página Hoje)
    @Published private(set) var resumeAt: Date?
    let resumes = PassthroughSubject<Resume.Info, Never>()
    @Published private(set) var summary: String?            // resumo do dia (fase 3)
    @Published private(set) var summaryBusy = false
    @Published var showSummary = false                       // página Hoje mostra o resumo no lugar da lista
    let summaries = PassthroughSubject<Void, Never>()        // resumo novo feito no bloqueio: avisa ao desbloquear
    private var summaryPending = false
    @Published var paused = Prefs.bool(Prefs.Key.activityPaused) {
        didSet { UserDefaults.standard.set(paused, forKey: Prefs.Key.activityPaused); tick() }
    }

    private let store = ActivityStore()
    private var tracker = ActivityTracker()
    private let axQueue = DispatchQueue(label: "iland.activity.ax", qos: .utility)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var repos: [String] = []                 // projetos conhecidos (com .git e pastas de 1º nível)
    private var reposAt = Date.distantPast
    private var recentPaths: [String] = []          // projetos achados por caminho, do mais antigo ao mais novo
    private var sessions: [ClaudeSessions.Session] = []
    private var sessionsAt = Date.distantPast
    private var lastSave = Date.distantPast
    private var locked = false
    private var resumeGate = ResumeGate(lastSeen: [:])   // "onde parei": só depois de 5 min seguidos no projeto
    private let debug = ProcessInfo.processInfo.environment["ILAND_ACTIVITY_DEBUG"] != nil

    static let editors = Editor.bundles
    static let terminals = Terminal.bundles
    static let claudeApp = "com.anthropic.claudefordesktop"

    func start() {
        guard timer == nil else { return }
        if let s = store.recoverCurrent() { store.append([s]) }   // sobrou de um crash
        store.prune(now: Date())
        var seen: [String: Date] = [:]   // quando cada projeto foi visto pela última vez (para o "onde parei")
        for d in 0..<7 {
            guard let day = Calendar.current.date(byAdding: .day, value: -d, to: Date()) else { continue }
            for s in store.day(day) { if let p = s.project, s.end > (seen[p] ?? .distantPast) { seen[p] = s.end } }
        }
        resumeGate = ResumeGate(lastSeen: seen)
        if !trusted, !Prefs.bool(Prefs.Key.axPrompted), Prefs.bool(Prefs.Key.onboarded) {   // pede a permissão uma vez; depois só mostra o aviso na página
            UserDefaults.standard.set(true, forKey: Prefs.Key.axPrompted)
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() })
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.closeNow() })
        }
        let dist = DistributedNotificationCenter.default()
        observers.append(dist.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.locked = true; self.closeNow()
            // Fim do expediente: 1º bloqueio a partir das 17h faz o resumo do dia (uma vez por dia).
            if DailySummary.shouldRun(now: Date(), lastRunDay: UserDefaults.standard.string(forKey: Prefs.Key.summaryDay)) {
                UserDefaults.standard.set(DailySummary.dayKey(Date()), forKey: Prefs.Key.summaryDay)
                self.makeSummary(announce: true)
            }
        })
        observers.append(dist.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.locked = false; self.tick()
            if self.summaryPending, !self.summaryBusy { self.summaryPending = false; self.showSummary = true; self.summaries.send() }
        })
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 5
        timer = t
        refreshToday()   // a página Hoje e o painel "Agora" já abrem com o dia, mesmo com a tela bloqueada
        tick()
    }

    /// Fecha o trecho aberto (sono, bloqueio, troca de usuário) e grava.
    private func closeNow() {
        store.append(tracker.close(at: Date()))
        store.saveCurrent(nil)
        refreshToday()
    }

    /// Lê a janela da frente fora da main thread e entrega a amostra de volta na main.
    private func tick() {
        guard !locked, let app = NSWorkspace.shared.frontmostApplication else { return }
        guard Prefs.assistantActive() else {   // fora do expediente (7h–19h)
            if tracker.open != nil { closeNow() }
            // Fim do expediente sem resumo (não bloqueou a tela depois das 17h): faz agora, uma vez.
            if DailySummary.shouldRun(now: Date(), lastRunDay: UserDefaults.standard.string(forKey: Prefs.Key.summaryDay)),
               Calendar.current.component(.hour, from: Date()) >= UserDefaults.standard.integer(forKey: Prefs.Key.assistantTo) {
                UserDefaults.standard.set(DailySummary.dayKey(Date()), forKey: Prefs.Key.summaryDay)
                makeSummary(announce: true)
            }
            return
        }
        let bundle = app.bundleIdentifier ?? "", name = app.localizedName ?? bundle, pid = app.processIdentifier
        // Tela bloqueada sem o aviso (ou protetor de tela): fecha o trecho e não abre outro.
        if ActivitySummary.away.contains(name) { if tracker.open != nil { closeNow() }; return }
        let paused = self.paused, needRepos = Date().timeIntervalSince(reposAt) > 3600
        let needSessions = Date().timeIntervalSince(sessionsAt) > 300 && (bundle == Self.claudeApp || Self.editors.contains(bundle))
        axQueue.async { [weak self] in
            let trusted = AXIsProcessTrusted()
            let w = trusted ? Self.frontWindow(pid: pid) : (title: nil, document: nil, secureField: false)
            let isBrowser = PrivacyGate.isBrowser(bundle)
            let mode = PrivacyGate.modeAware.contains(bundle) ? Self.browserMode(bundle) : nil
            let repos = needRepos ? ProjectRoots.scan() : nil
            let sessions = needSessions ? ClaudeSessions.recent() : nil
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            let verdict = PrivacyGate.decide(PrivacyInput(bundleID: bundle, title: w.title ?? "", isBrowser: isBrowser, browserMode: mode,
                                                          secureInput: IsSecureEventInputEnabled(), focusedIsSecureField: w.secureField, paused: paused))
            DispatchQueue.main.async {
                guard let self else { return }
                self.trusted = trusted
                if let repos { self.repos = repos; self.reposAt = Date() }
                if let sessions { self.sessions = sessions; self.sessionsAt = Date() }
                self.record(app: name, bundle: bundle, verdict: verdict, document: w.document, lastInput: Date().addingTimeInterval(-idle))
            }
        }
    }

    private func record(app: String, bundle: String, verdict: PrivacyGate.Verdict, document: String?, lastInput: Date) {
        let exists = { (p: String) in FileManager.default.fileExists(atPath: p + "/.git") }
        // Caminho -> projeto: repositório mais fundo; sem .git, a pasta de projeto conhecida que contém o caminho.
        let known = repos
        let projectFor = { (path: String) -> String? in
            ProjectResolver.root(forPath: path, exists: exists)
                ?? known.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        }
        // Projeto por caminho (vale até para privado): documento da janela ou sessão do app do Claude das últimas 2 h.
        var project = document.flatMap { projectFor(URL(string: $0)?.isFileURL == true ? (URL(string: $0)?.path ?? $0) : $0) }
        if project == nil, bundle == Self.claudeApp,
           let s = sessions.last(where: { $0.entrypoint == "claude-desktop" && Date().timeIntervalSince($0.timestamp) < 7200 }) {
            project = projectFor(s.cwd)
        }
        if let p = project, recentPaths.last != p {
            recentPaths.append(p); recentPaths = Array(recentPaths.suffix(20))
            if !repos.contains(p) { ProjectRoots.learn(p); reposAt = .distantPast }   // projeto novo: busca de novo no próximo ciclo
        }
        var title: String?, reason: String?
        switch verdict {
        case .ok(let t): title = t.isEmpty ? nil : t
        case .private(let r): reason = r
        }
        // Projeto pelo título (Cursor/VS Code: "arquivo — pasta"; Terminal: "pasta — processo"): só fora do privado.
        let folderFromTitle = title.flatMap { t in
            Self.editors.contains(bundle) ? ProjectResolver.folderName(fromTitle: t)
                : (Self.terminals.contains(bundle) ? ProjectResolver.terminalFolder(fromTitle: t) : nil)
        }
        if project == nil, let folder = folderFromTitle {
            // Nome repetido (2 "Project Demo"): as pastas das sessões do Claude também servem de pista, junto com o que veio por caminho.
            let hints = sessions.compactMap { projectFor($0.cwd) } + recentPaths
            project = ProjectResolver.match(name: folder, repos: repos, recent: hints)
        }
        // Onde parei: 5 min seguidos de volta a um projeto que ficou 1 h ou mais sem estadia de verdade.
        if let p = resumeGate.observe(project: project.flatMap { $0.hasPrefix("/") ? $0 : nil }, now: Date()) {
            axQueue.async { [weak self] in
                let info = Resume.gather(project: p, sessions: ClaudeSessions.recent())
                DispatchQueue.main.async { self?.resume = info; self?.resumeAt = Date(); self?.resumes.send(info) }
            }
        }
        let closed = tracker.observe(Sample(app: app, title: title, project: project, privateReason: reason, lastInput: lastInput), now: Date())
        store.append(closed)
        if debug {
            for s in closed { NSLog("iLand activity: %@ %@ %@ %.0fs", s.app, s.project ?? "-", s.privateReason.map { "privado(\($0))" } ?? (s.title ?? "-"), s.seconds) }
        }
        if !closed.isEmpty || Date().timeIntervalSince(lastSave) >= 60 { store.saveCurrent(tracker.open); lastSave = Date() }
        refreshToday()
    }

    /// Resumo do dia pelo `claude -p` (só texto limpo); sem resposta, fica o resumo só com os números.
    func makeSummary(announce: Bool = false) {
        guard !summaryBusy else { return }
        summaryBusy = true
        var segs = store.day(Date())
        if let o = tracker.open { segs.append(o) }
        let since = Calendar.current.startOfDay(for: Date()), day = DailySummary.dayKey(Date())
        axQueue.async { [weak self] in
            let days = DailySummary.enrich(DailySummary.projects(segs), sessions: ClaudeSessions.recent(), since: since)
            DispatchQueue.main.async {
                guard !days.isEmpty else { self?.finishSummary("Nada registrado hoje.", day: day, announce: announce); return }
                LLM.ask(DailySummary.prompt(days, day: day), role: .summary) { text in
                    let ok = !text.hasPrefix("Não consegui") && !text.hasPrefix("Não achei") && text != "(sem resposta)"
                    self?.finishSummary(ok ? text : DailySummary.fallback(days), day: day, announce: announce)
                }
            }
        }
    }

    private func finishSummary(_ text: String, day: String, announce: Bool) {
        summary = text; summaryBusy = false
        DailySummary.save(text, day: day)
        if announce { if locked { summaryPending = true } else { showSummary = true; summaries.send() } }
        else { showSummary = true }
    }

    var isLocked: Bool { locked }

    /// Trechos desde `since` (arquivos do dia e de ontem + o trecho aberto). Para o vigia do timer.
    func segments(since: Date) -> [Segment] {
        var segs = store.day(Date())
        if !Calendar.current.isDateInToday(since), let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) { segs = store.day(y) + segs }
        if let o = tracker.open { segs.append(o) }
        return segs.filter { $0.end > since }
    }

    /// Trechos de um dia inteiro (o de hoje inclui o trecho aberto). Para o assistente responder sobre dias passados.
    func segments(onDay d: Date) -> [Segment] {
        var segs = store.day(d)
        if Calendar.current.isDateInToday(d), let o = tracker.open { segs.append(o) }
        return segs
    }

    private func refreshToday() {
        var segs = store.day(Date())
        if let o = tracker.open { segs.append(o) }
        let rows = ActivitySummary.byProject(segs)
        if rows != today { today = rows }
    }

    /// Título, documento (caminho/URL) e se o elemento em foco é um campo de senha. Timeout de 1 s por chamada.
    private static func frontWindow(pid: pid_t) -> (title: String?, document: String?, secureField: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        var title: String?, doc: String?, secure = false
        if let w = attr(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            let win = w as! AXUIElement
            title = attr(win, kAXTitleAttribute) as? String
            doc = attr(win, kAXDocumentAttribute) as? String
        }
        if let f = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
            secure = (attr(f as! AXUIElement, kAXSubroleAttribute) as? String) == (kAXSecureTextFieldSubrole as String)
        }
        return (title, doc, secure)
    }

    /// Chrome/Arc: "normal" ou "incognito" da janela da frente (pede a permissão de Automação uma vez). Erro = nil = privado.
    /// Texto fixo por app (nada de fora entra no script).
    private static func browserMode(_ bundle: String) -> String? {
        let src = bundle == "company.thebrowser.Browser"
            ? "tell application \"Arc\" to if (count of windows) > 0 then return (incognito of front window) as text"
            : "tell application \"Google Chrome\" to if (count of windows) > 0 then return mode of front window"
        var err: NSDictionary?
        guard let r = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue, err == nil else { return nil }
        return r == "false" ? "normal" : (r == "true" ? "incognito" : r)
    }
}
