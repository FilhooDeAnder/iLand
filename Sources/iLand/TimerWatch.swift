import AppKit
import Combine

/// Cartão do vigia do timer na página Hoje.
struct TimerCard: Equatable {
    enum Kind: Equatable {
        case mismatch(project: String, since: Date)     // timer em T (projeto A), mas você está em B
        case away(from: Date, to: Date)                 // timer rodou com você longe
        case askProject(options: [String])              // 1ª vez com a task: de qual projeto?
    }
    let key: String
    let entry: ClickUp.Entry
    let kind: Kind
}

/// Cérebro, fase 1: vigia do timer do ClickUp. A cada 2 min (tela desbloqueada, token presente) compara o timer com o
/// log de atividade (TimerRules, puro). Mostra o cartão só em pausa da digitação. Zero token de LLM.
/// Arquivos em ~/Library/Application Support/iLand/brain/ (0700/0600): links.json, decisions.jsonl, outcomes.jsonl.
final class TimerWatch: ObservableObject {
    @Published private(set) var card: TimerCard?
    @Published private(set) var status = ""              // "Conectar ClickUp", erro, etc. (página Hoje)
    @Published private(set) var busy = false
    @Published private(set) var lastEntry: ClickUp.Entry?  // timer rodando agora (orelha, Ferramentas e cérebro)
    @Published private(set) var paused: ClickUp.Paused? = ClickUp.Paused.load()   // task pausada pelo iLand
    @Published private(set) var connected = false           // há token no Keychain
    let cards = PassthroughSubject<TimerCard, Never>()
    private weak var activity: ActivitySensor?
    private var links = TimerLinks()
    private var gate = TimerGate()
    private var pending: TimerCard?
    private var timer: Timer?
    private var authFailed = false
    private let dir: URL

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLand/brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let d = try? Data(contentsOf: dir.appendingPathComponent("links.json")), let l = try? JSONDecoder().decode(TimerLinks.self, from: d) { links = l }
    }

    func start(activity: ActivitySensor) {
        self.activity = activity
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 10
        timer = t
        tick()
    }

    /// Depuração (ILAND_TIMER_DEMO=1): cartão inventado, sem API.
    func demo() {
        let e = ClickUp.Entry(id: "demo", taskId: "t", taskName: "Demo: revisar documentação", start: Date().addingTimeInterval(-6 * 3600))
        show(TimerCard(key: "demo", entry: e, kind: .mismatch(project: "/p/project-b", since: Date().addingTimeInterval(-28 * 60))))
    }

    /// O timer é lido sempre que há token (orelha e Ferramentas). O vigia só age com o assistente ativo.
    private func tick() {
        guard let activity, !activity.isLocked, !authFailed else { return }
        let watching = Prefs.assistantActive()
        if watching, let p = pending { return show(p) }   // esperando uma pausa na digitação
        refresh(evaluate: watching)
    }

    /// Lê o timer agora (também ao abrir a página Ferramentas e depois de pausar ou continuar).
    func refresh(evaluate: Bool = false) {
        guard !authFailed else { return }
        Task { @MainActor in
            // Token fora da main (o Keychain pode pedir permissão e esperar).
            let hasToken = await Task.detached { ClickUp.token() != nil }.value
            self.connected = hasToken
            guard hasToken else { self.status = "Conectar ClickUp: token no Keychain (iland-clickup)"; return }
            do {
                let entry = try await ClickUp.current()
                self.status = ""
                self.lastEntry = entry
                guard let entry else { self.card = nil; return }
                self.setPaused(nil)   // outro timer rodando: "Continuar" voltaria para a task errada
                if evaluate { self.evaluate(entry, now: Date()) }
            } catch ClickUp.Failure.unauthorized {
                self.authFailed = true; self.status = "ClickUp recusou o token (401). Gere outro e salve no Keychain."
            } catch { self.status = "ClickUp fora do ar; tento de novo em 2 min." }
        }
    }

    /// Pausar = fechar a entrada de tempo atual. A task fica guardada para "Continuar".
    func pause() {
        guard let e = lastEntry, !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                try await ClickUp.stop()
                self.lastEntry = nil; self.card = nil
                self.setPaused(ClickUp.Paused(taskId: e.taskId, taskName: e.taskName))
            } catch { self.status = "Não consegui pausar no ClickUp." }
            self.busy = false
        }
    }

    /// Continuar = abrir uma entrada nova na task pausada.
    func resume() {
        guard let p = paused, lastEntry == nil, !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                try await ClickUp.start(task: p.taskId)
                self.setPaused(nil)   // antes de ler: se a leitura falhar, não abre a mesma task duas vezes
                self.lastEntry = try? await ClickUp.current()
            } catch { self.status = "Não consegui continuar no ClickUp." }
            self.busy = false
        }
    }

    private func setPaused(_ p: ClickUp.Paused?) {
        guard paused != p else { return }
        paused = p
        ClickUp.Paused.save(p)
    }

    private func evaluate(_ entry: ClickUp.Entry, now: Date) {
        guard let activity, !links.isIgnored(entry.taskId) else { return }
        let segs = activity.segments(since: entry.start)
        guard let a = links.taskProject[entry.taskId] else {
            // 1ª vez com esta task: pergunta o projeto (os por caminho desde o início do timer, mais usados primeiro).
            var mins: [String: Double] = [:]
            for s in segs where s.privateReason == nil { if let p = s.project, p.hasPrefix("/") { mins[p, default: 0] += s.seconds } }
            let options = Array(mins.sorted { $0.value > $1.value }.prefix(4).map(\.key))
            if !options.isEmpty, gate.shouldShow("ask|\(entry.taskId)", now: now) {
                show(TimerCard(key: "ask|\(entry.taskId)", entry: entry, kind: .askProject(options: options)))
            }
            return
        }
        // Projetos que a pessoa confirmou que também contam para esta task viram A.
        let mapped = segs.map { s -> Segment in
            var s = s
            if let p = s.project, links.counts(task: entry.taskId, project: p, now: now) { s.project = a }
            return s
        }
        if let away = TimerRules.absence(segments: mapped, entryStart: entry.start, now: now) {
            let key = "\(entry.id)|away:\(Int(away.from.timeIntervalSince1970))"
            if gate.shouldShow(key, now: now) { return show(TimerCard(key: key, entry: entry, kind: .away(from: away.from, to: away.to))) }
        }
        if let m = TimerRules.mismatch(segments: mapped, now: now, project: a) {
            let key = "\(entry.id)|\(m.project)"
            if gate.shouldShow(key, now: now) { show(TimerCard(key: key, entry: entry, kind: .mismatch(project: m.project, since: m.since))) }
        }
    }

    /// Só aparece em pausa da digitação (> 10 s sem tecla); senão espera o próximo tick (≤ 2 min).
    private func show(_ c: TimerCard) {
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        guard sinceKey > 10 || c.key == "demo" else { pending = c; return }
        pending = nil
        card = c
        log("decisions", ["kind": "\(c.kind)", "key": c.key, "task": c.entry.taskName])
        cards.send(c)
    }

    /// Para o cérebro: timer atual e ligações confirmadas (sem token, sem ids internos além da task).
    func statusText() -> String {
        var out = lastEntry.map { "Timer rodando: \"\($0.taskName)\" desde \(DateFormatter.localizedString(from: $0.start, dateStyle: .none, timeStyle: .short))." } ?? "Nenhum timer rodando (ou ClickUp não consultado ainda)."
        let named = links.taskProject.map { "task \($0.key) → \(ProjectResolver.display($0.value))" }
        if !named.isEmpty { out += "\nLigações task→projeto: " + named.joined(separator: "; ") }
        if !links.ignored.isEmpty { out += "\nTasks não vigiadas: \(links.ignored.count)" }
        return out
    }

    /// Últimas decisões do vigia (para a memória do cérebro).
    func recentOutcomes(_ n: Int = 10) -> String {
        let url = dir.appendingPathComponent("outcomes.jsonl")
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").suffix(n)
        return lines.isEmpty ? "(nenhuma decisão registrada)" : lines.joined(separator: "\n")
    }

    /// Proposta aprovada do cérebro: parar o timer (agora ou às HH:MM de hoje).
    func execute(_ p: BrainProposal, completion: @escaping (String) -> Void) {
        Task { @MainActor in
            do {
                guard let e = try await ClickUp.current() else { return completion("Não há timer rodando.") }
                try await ClickUp.stop()
                if p.kind == "stop_timer_at", let at = p.at, let end = Self.today(at), end > e.start {
                    try await ClickUp.update(entry: e.id, start: e.start, end: end)
                    completion("Timer parado e corrigido para terminar às \(at).")
                } else { completion("Timer parado.") }
                self.log("outcomes", ["key": "brain|\(e.id)", "action": p.kind])
            } catch { completion("Não consegui falar com o ClickUp.") }
        }
    }

    static func today(_ hhmm: String) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }

    // MARK: ações do cartão

    enum Action { case stopAt(Date), stopNow, itsFine, ignoreTask, discount(from: Date), keep, project(String), dismiss }

    /// `key`: a ação veio de uma mensagem da conversa; só vale se o cartão ainda for o mesmo. `done`: resultado legível.
    func act(_ a: Action, key: String? = nil, done: ((String) -> Void)? = nil) {
        guard let c = card, key == nil || c.key == key else { done?("Esse aviso já foi resolvido."); return }
        doneHandler = done
        log("outcomes", ["key": c.key, "action": "\(a)"])
        let e = c.entry
        switch a {
        case .itsFine:
            if case .mismatch(let p, _) = c.kind { links.allow(task: e.taskId, project: p, now: Date()) }
            gate.resolve(c.key); saveLinks(); card = nil; finish("Ok, esse projeto conta para a task por 30 dias.")
        case .ignoreTask: links.ignored.insert(e.taskId); gate.resolve(c.key); saveLinks(); card = nil; finish("Não vigio mais essa task.")
        case .keep, .dismiss: gate.resolve(c.key); card = nil; finish("Mantido.")
        case .project(let p): links.taskProject[e.taskId] = p; gate.resolve(c.key); saveLinks(); card = nil; finish("Guardei: a task é de \(ProjectResolver.display(p)).")
        case .stopNow: run(c) { try await ClickUp.stop() }
        case .stopAt(let end): run(c) { try await ClickUp.stop(); try await ClickUp.update(entry: e.id, start: e.start, end: end) }
        case .discount(let from):
            // Termina a entrada no começo da ausência e abre uma nova agora (o tempo longe some).
            run(c) { try await ClickUp.stop(); try await ClickUp.update(entry: e.id, start: e.start, end: from); try await ClickUp.start(task: e.taskId) }
        }
    }

    private func run(_ c: TimerCard, _ work: @escaping () async throws -> Void) {
        busy = true
        Task { @MainActor in
            do { try await work(); self.gate.resolve(c.key); self.card = nil; self.status = ""; self.finish("Feito no ClickUp.") }
            catch { self.status = "Não consegui falar com o ClickUp; nada foi alterado além do que já foi."; self.finish(self.status) }
            self.busy = false
        }
    }

    private var doneHandler: ((String) -> Void)?
    private func finish(_ s: String) { doneHandler?(s); doneHandler = nil }

    private func saveLinks() {
        let url = dir.appendingPathComponent("links.json")
        if let d = try? JSONEncoder().encode(links) { try? d.write(to: url, options: .atomic) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func log(_ name: String, _ fields: [String: String]) {
        var f = fields; f["ts"] = ISO8601DateFormatter().string(from: Date())
        guard let d = try? JSONSerialization.data(withJSONObject: f, options: .sortedKeys) else { return }
        let url = dir.appendingPathComponent("\(name).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: d + Data("\n".utf8)); try? h.close() }
    }
}
