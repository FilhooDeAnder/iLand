import Foundation
import IOKit.pwr_mgt
import Combine

/// Relógio de 1 s das contagens. Separado do ToolsModel para que só quem mostra tempo (orelha, página, barra de menus) redesenhe a cada
/// segundo, e não a tela inteira do notch.
final class Ticker: ObservableObject {
    @Published var now = Date()
    var visible = false   // notch fechado: ninguém na tela precisa do relógio, então não publica
}

/// Cafeína, cronômetro e pomodoro. Estado local; o relógio de 1 s só existe enquanto algo está rodando
/// (com tudo parado não há timer, então o app em repouso não gasta nada por causa disto).
final class ToolsModel: ObservableObject {
    @Published private(set) var pomodoro = PomodoroEngine()
    @Published private(set) var stopwatch = Stopwatch()
    @Published private(set) var caffeine = Caffeine()
    let ticker = Ticker()
    /// A barra de menus mostra a contagem mesmo com o notch fechado: tem o próprio sinal, que não redesenha nada do notch.
    let statusClock = PassthroughSubject<Void, Never>()
    var now: Date { ticker.now }
    func setVisible(_ v: Bool) {
        ticker.visible = v
        if v { ticker.now = Date(); readLidAwake() }
    }

    var hasTimer: Bool { !pomodoro.isIdle || !stopwatch.isIdle }
    let sound = SoundModel()
    let capture = CaptureModel()
    let shortcuts = ShortcutsModel()
    let notes = NotesModel()
    let clipboard = ClipboardModel()
    let shelf = ShelfModel()
    lazy var agent = AgentController(brain: brain, timer: timerWatch, notes: notes)
    private var agentSinks: [AnyCancellable] = []
    private var opener = ProjectOpener { Editor.open($0) }
    let machines = MachinesMonitor()
    let tunnels = TunnelManager()
    let activity = ActivitySensor()
    let timerWatch = TimerWatch()
    let brain = BrainClient()
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    init() {
        readLidAwake()
        agent.core = { [weak self] in self?.brainCore() ?? "" }
        brain.handlers = [
            "day_log": { [weak self] a, _, reply in reply(self?.dayLog(a["date"] as? String) ?? "") },
            "project_info": { [weak self] a, _, reply in
                let name = a["project"] as? String ?? ""
                DispatchQueue.global(qos: .userInitiated).async { let r = self?.projectInfo(name) ?? ""; reply(r) }   // git e arquivos fora da main
            },
            "timer_status": { [weak self] _, _, reply in reply(self?.timerWatch.statusText() ?? "") },
            "memory_query": { [weak self] _, _, reply in
                let m = BrainMemory.read()
                reply("Memória (confirmada por \(Prefs.userName)):\n" + (m.isEmpty ? "(vazia)" : m) + "\n\nDecisões recentes do vigia do timer:\n" + (self?.timerWatch.recentOutcomes() ?? ""))
            },
            "my_tasks": { _, _, reply in
                Task.detached {   // rede e Keychain fora da main
                    do { reply(ClickUp.tasksText(try await ClickUp.myTasks())) }
                    catch ClickUp.Failure.noToken { reply("ClickUp não conectado (sem token no Keychain).") }
                    catch { reply("Não consegui ler as tasks do ClickUp agora.") }
                }
            },
            "open_project": { [weak self] a, ask, reply in reply(self?.opener.open(a["project"] as? String ?? "", ask: ask) ?? "") },
        ]
        // Eventos das regras viram mensagens proativas na conversa (sem modelo).
        agentSinks = [
            timerWatch.cards.sink { [weak self] c in self?.agent.timerCard(c) },
            activity.resumes.sink { [weak self] info in
                let name = ProjectResolver.display(info.project)
                let canOpen = ProjectOpener.validate((info.project as NSString).lastPathComponent, roots: ProjectOpener.defaultRoots) != nil
                self?.agent.proactive("Você voltou ao \(name). Onde parou:\n" + info.lines.map { "• " + $0 }.joined(separator: "\n"),
                                      actions: canOpen ? [AgentAction(id: UUID().uuidString, title: "Abrir no \(Editor.name)", kind: "open.project", arg: (info.project as NSString).lastPathComponent)] : [],
                                      chips: [name])
            },
            activity.summaries.sink { [weak self] in
                if let s = self?.activity.summary { self?.agent.proactive(s, chips: ["resumo do dia"], always: true) }
            },
            machines.notices.sink { [weak self] n in
                if n.level == .crit { self?.agent.proactive("Máquina \(n.alias) em vermelho: \(n.text).", chips: ["máquinas"]) }
            },
        ]
    }

    /// Contexto curto (~50 tokens) que vai com cada pergunta.
    private func brainCore() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEEE dd/MM HH:mm"
        let top = activity.today.first.map { "projeto com mais tempo hoje: \(ProjectResolver.display($0.project))" } ?? ""
        return "Agora: \(f.string(from: Date())) (\(DailySummary.dayKey(Date()))). \(top). \(timerWatch.statusText())"
    }

    /// Tempo por projeto e as janelas mais longas de um dia (títulos já limpos; privados só contam tempo), mais o resumo
    /// do dia que ficou salvo. `date` = AAAA-MM-DD; sem data ou data inválida = hoje.
    private func dayLog(_ date: String?) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let day = date.flatMap { f.date(from: $0) } ?? Date()
        let key = DailySummary.dayKey(day)
        let w = DateFormatter(); w.locale = Locale(identifier: "pt_BR"); w.dateFormat = "EEEE dd/MM"
        let head = "Dia \(key) (\(w.string(from: day)))"
        let days = DailySummary.projects(activity.segments(onDay: day))
        var out = days.isEmpty ? ["\(head): nada registrado (o registro guarda 30 dias e só funciona com a Acessibilidade)."] : ["\(head):"] + days.prefix(12).map { d in
            "\(d.name): \(DailySummary.hm(d.minutes))" + (d.privateMinutes > 0 ? " (\(DailySummary.hm(d.privateMinutes)) privado)" : "")
                + (d.titles.isEmpty ? "" : " — janelas: " + d.titles.joined(separator: " | "))
        }
        if let s = DailySummary.load(day: key) { out.append("\nResumo salvo desse dia (feito pelo iLand):\n" + String(s.prefix(3000))) }
        return out.joined(separator: "\n")
    }

    /// "Onde parei" de um projeto pelo nome da pasta (hoje ou nas pastas de projeto conhecidas).
    private func projectInfo(_ name: String) -> String {
        guard name.range(of: "^[A-Za-z0-9._ -]{1,80}$", options: .regularExpression) != nil else { return "Nome de projeto inválido." }
        let fromToday = activity.segments(since: Calendar.current.startOfDay(for: Date())).compactMap(\.project)
            .first { $0.hasPrefix("/") && ProjectResolver.display($0).caseInsensitiveCompare(name) == .orderedSame }
        let candidates = ProjectRoots.openRoots().map { "\($0)/\(name)" }
        guard let path = fromToday ?? candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return "Não achei o projeto \(name)." }
        let info = Resume.gather(project: path, sessions: ClaudeSessions.recent())
        return "\(ProjectResolver.display(path)):\n" + info.lines.joined(separator: "\n")
    }

    var anyRunning: Bool { pomodoro.isRunning || stopwatch.isRunning || caffeine.isOn }

    /// Rótulo e valor para a orelha esquerda e a barra de menus: pomodoro, senão cronômetro.
    var earText: (label: String, value: String)? {
        if let r = pomodoro.remaining(now: now), !pomodoro.isIdle { return (pomodoro.phase.title.lowercased(), TimeFmt.clock(r)) }
        if !stopwatch.isIdle { return ("cron", TimeFmt.clock(stopwatch.elapsed(now: now))) }
        return nil
    }

    // MARK: pomodoro
    func togglePomodoro() {
        pomodoro.isRunning ? pomodoro.pause(now: Date()) : pomodoro.start(now: Date())
        refresh()
    }
    func skipPomodoro() { pomodoro.skip(now: Date()); refresh() }
    func resetPomodoro() { pomodoro.reset(); refresh() }

    // MARK: cronômetro
    func toggleStopwatch() {
        stopwatch.isRunning ? stopwatch.pause(now: Date()) : stopwatch.start(now: Date())
        refresh()
    }
    func resetStopwatch() { stopwatch.reset(); refresh() }

    // MARK: cafeína
    /// minutos = nil: sem fim.
    func turnOnCaffeine(minutes: Int?) {
        caffeine.turnOn(for: minutes.map { TimeInterval($0 * 60) }, now: Date())
        if assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "iLand: cafeína (manter o Mac acordado)" as CFString, &assertion)
        }
        refresh()
    }
    func turnOffCaffeine() { caffeine.turnOff(); releaseAssertion(); refresh() }

    // MARK: tampa fechada (pmset disablesleep)
    /// Mac acordado mesmo com a tampa fechada. Fica gravado no sistema (sobrevive a reiniciar) até desligar aqui.
    @Published private(set) var lidAwake = false

    /// Lê o estado real do sistema: alguém pode ter mudado pelo terminal.
    func readLidAwake() {
        DispatchQueue.global(qos: .utility).async {
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); t.arguments = ["-g"]
            let out = Pipe(); t.standardOutput = out; t.standardError = FileHandle.nullDevice
            guard (try? t.run()) != nil else { return }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); t.waitUntilExit()
            let on = text.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
            DispatchQueue.main.async { if self.lidAwake != on { self.lidAwake = on } }
        }
    }

    /// Sem senha: `sudo -n` com uma regra em /etc/sudoers.d/iland que libera só `pmset -a disablesleep 0|1`.
    /// Sem a regra, pede a senha de administrador UMA vez para instalá-la (conferida pelo visudo) e já aplica.
    func toggleLidAwake() {
        let value = lidAwake ? "0" : "1"
        DispatchQueue.global(qos: .userInitiated).async {
            if Self.exec("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]) != 0 { Self.installSudoRule(then: value) }
            self.readLidAwake()
        }
    }

    @discardableResult private static func exec(_ exe: String, _ args: [String]) -> Int32 {
        let t = Process(); t.executableURL = URL(fileURLWithPath: exe); t.arguments = args
        t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
        guard (try? t.run()) != nil else { return -1 }
        t.waitUntilExit(); return t.terminationStatus
    }

    private static func installSudoRule(then value: String) {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else { return }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iland-sudoers-\(UUID().uuidString)")
        guard (try? rule.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Caminho e valor entram como argv (quoted form), nada interpolado no script.
        let script = """
        on run argv
            set f to quoted form of item 1 of argv
            do shell script "/usr/sbin/visudo -cf " & f & " && /usr/bin/install -m 0440 -o root -g wheel " & f & " /etc/sudoers.d/iland && /usr/bin/pmset -a disablesleep " & item 2 of argv with administrator privileges
        end run
        """
        exec("/usr/bin/osascript", ["-e", script, tmp.path, value])
    }

    private func releaseAssertion() { if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 } }

    // MARK: relógio
    private func refresh() {
        ticker.now = Date()
        if anyRunning, timer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.2
            timer = t
        } else if !anyRunning {
            timer?.invalidate(); timer = nil
        }
    }

    private func tick() {
        let t = Date()
        if ticker.visible { ticker.now = t }
        statusClock.send()
        // Mutar uma propriedade @Published avisa todos os observadores mesmo sem mudança: só atribui se algo mudou.
        var p = pomodoro
        if let finished = p.tick(now: t) {
            pomodoro = p
            switch finished {
            case .focus: Notifier.send(title: "Foco concluído", message: "Hora de uma pausa de \(Int(pomodoro.duration(pomodoro.phase) / 60)) min.", id: "pomodoro")
            default: Notifier.send(title: "Pausa acabou", message: "Bora voltar ao foco.", id: "pomodoro")
            }
        }
        var c = caffeine
        if c.expire(now: t) { caffeine = c; releaseAssertion() }
        if !anyRunning { timer?.invalidate(); timer = nil }
    }
}
