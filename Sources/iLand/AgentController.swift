import AppKit
import Combine

/// A conversa com o assistente (uma só, para a janela e o notch). Perguntas vão ao cérebro com streaming; eventos das
/// regras (timer, onde parei, resumo, máquinas) entram como mensagens proativas, com botões. Uma pergunta por vez.
final class AgentController: ObservableObject {
    enum Orb { case idle, thinking, attention, paused }

    @Published private(set) var messages: [AgentMessage] = []
    @Published var draft = ""
    @Published private(set) var busy = false
    @Published private(set) var orb: Orb = .idle
    let attention = PassthroughSubject<AgentMessage, Never>()   // proativa nova: a orelha avisa

    private let store = ThreadStore()
    private let brain: BrainClient
    private weak var timer: TimerWatch?
    private weak var notes: NotesModel?
    private var proposals: [String: BrainProposal] = [:]   // id da ação -> proposta
    private var day = DailySummary.dayKey(Date())
    private var fallback: Process?
    var core: () -> String = { "" }

    init(brain: BrainClient, timer: TimerWatch, notes: NotesModel) {
        self.brain = brain; self.timer = timer; self.notes = notes
        store.prune(now: Date())
        messages = store.day(Date())
    }

    var lastAssistant: AgentMessage? { messages.last { $0.role != .user } }

    // MARK: perguntar

    func send(_ raw: String? = nil) {
        let text = (raw ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        rollDay()
        draft = ""
        add(AgentMessage(role: .user, text: text))
        var reply = AgentMessage(role: .assistant, text: "")
        reply.state = "pensando…"
        messages.append(reply)
        let rid = reply.id
        busy = true; orb = .thinking
        let cb = BrainClient.Callbacks(
            delta: { [weak self] t in self?.edit(rid) { $0.text += t; $0.state = nil } },
            tool: { [weak self] name, args in
                let chip = AgentChips.label(for: name, args: args)
                self?.edit(rid) { if !$0.chips.contains(chip) { $0.chips.append(chip) } }
            },
            proposal: { [weak self] p in self?.attachProposal(p, to: rid) },
            done: { [weak self] final in self?.finish(rid, final) })
        let used = brain.ask(text, core: core(), id: rid, callbacks: cb) { [weak self] restarted in
            // Sessão nova com histórico na tela: avisa que o modelo não lembra do que está acima.
            if restarted, let self, self.messages.filter({ $0.role == .assistant && $0.id != rid }).count > 0 {
                self.edit(rid) { $0.chips.insert("contexto reiniciado", at: 0) }
            }
        }
        if !used {   // sem o cérebro: `claude -p` simples, sem ferramentas
            fallback = LLM.ask(text, role: .quick) { [weak self] t in self?.finish(rid, t) }
        }
    }

    func cancel() {
        guard busy else { return }
        fallback?.terminate(); fallback = nil
        brain.cancel()
    }

    private func finish(_ id: String, _ final: String) {
        edit(id) { $0.text = final; $0.state = nil }   // o texto final substitui o que veio em streaming
        if let m = messages.first(where: { $0.id == id }) { store.append(m) }
        busy = false; fallback = nil
        if orb == .thinking { orb = .idle }
    }

    // MARK: proativas (regras, sem modelo)

    /// `always`: o resumo do fim do expediente entra mesmo depois das 19h.
    func proactive(_ text: String, actions: [AgentAction] = [], chips: [String] = [], always: Bool = false) {
        guard always || Prefs.assistantActive() else { return }   // fora do expediente: sem avisos
        rollDay()
        var m = AgentMessage(role: .proactive, text: text, actions: actions)
        m.chips = chips
        add(m)
        orb = .attention
        attention.send(m)
    }

    func timerCard(_ c: TimerCard) {
        let task = c.entry.taskName
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        switch c.kind {
        case .mismatch(let p, let since):
            proactive("Seu timer está em “\(task)”, mas desde ~\(f.string(from: since)) você está em \(ProjectResolver.display(p)).", actions: [
                AgentAction(id: UUID().uuidString, title: "Parar às \(f.string(from: since))", kind: "timer.stopAt", arg: "\(c.key)|\(since.timeIntervalSince1970)"),
                AgentAction(id: UUID().uuidString, title: "Parar agora", kind: "timer.stopNow", arg: c.key),
                AgentAction(id: UUID().uuidString, title: "Está certo", kind: "timer.itsFine", arg: c.key),
                AgentAction(id: UUID().uuidString, title: "Não vigiar", kind: "timer.ignore", arg: c.key)], chips: ["timer do ClickUp"])
        case .away(let from, let to):
            let m = Int(to.timeIntervalSince(from) / 60)
            proactive("O timer de “\(task)” rodou \(m) min com você longe (\(f.string(from: from))–\(f.string(from: to))).", actions: [
                AgentAction(id: UUID().uuidString, title: "Descontar", kind: "timer.discount", arg: "\(c.key)|\(from.timeIntervalSince1970)"),
                AgentAction(id: UUID().uuidString, title: "Manter", kind: "timer.keep", arg: c.key)], chips: ["timer do ClickUp"])
        case .askProject(let options):
            proactive("A task “\(task)” é de qual projeto? Pergunto uma vez.", actions: options.map {
                AgentAction(id: UUID().uuidString, title: ProjectResolver.display($0), kind: "timer.project", arg: "\(c.key)|\($0)")
            } + [AgentAction(id: UUID().uuidString, title: "Nenhum", kind: "timer.ignore", arg: c.key)], chips: ["timer do ClickUp"])
        }
    }

    // MARK: botões

    func act(_ a: AgentAction, in messageId: String) {
        let done: (String) -> Void = { [weak self] s in self?.edit(messageId) { $0.state = s }; self?.persist(messageId) }
        let parts = (a.arg ?? "").components(separatedBy: "|")
        let key = parts.first
        switch a.kind {
        case "timer.stopAt": timer?.act(.stopAt(Date(timeIntervalSince1970: Double(parts.last ?? "") ?? 0)), key: key, done: done)
        case "timer.stopNow": timer?.act(.stopNow, key: key, done: done)
        case "timer.itsFine": timer?.act(.itsFine, key: key, done: done)
        case "timer.ignore": timer?.act(.ignoreTask, key: key, done: done)
        case "timer.keep": timer?.act(.keep, key: key, done: done)
        case "timer.discount": timer?.act(.discount(from: Date(timeIntervalSince1970: Double(parts.last ?? "") ?? 0)), key: key, done: done)
        case "timer.project": timer?.act(.project(parts.dropFirst().joined(separator: "|")), key: key, done: done)
        case "proposal.approve":
            guard let p = proposals.removeValue(forKey: a.arg ?? "") else { return done("Essa proposta já foi decidida.") }
            switch p.kind {
            case "remember": if let t = p.text { BrainMemory.append(t); done("Guardei na memória.") }
            case "note": if let t = p.text, let notes { notes.text += (notes.text.isEmpty ? "" : "\n") + t; done("Guardado nas Notas.") }
            default: done("Falando com o ClickUp…"); timer?.execute(p, completion: done)
            }
        case "proposal.reject": proposals[a.arg ?? ""] = nil; done("Recusado.")
        case "open.project": done(ProjectOpener.validate(a.arg ?? "", roots: ProjectOpener.defaultRoots).map { Editor.open($0); return "Abri no \(Editor.name)." } ?? "Não achei esse projeto.")
        default: done("(ação desconhecida)")
        }
        if orb == .attention { orb = .idle }
    }

    func seen() { if orb == .attention { orb = .idle } }

    // MARK: interno

    private func attachProposal(_ p: BrainProposal, to id: String) {
        let pid = UUID().uuidString
        proposals[pid] = p
        edit(id) {
            $0.actions += [AgentAction(id: UUID().uuidString, title: "Aprovar: \(p.summary)", kind: "proposal.approve", arg: pid),
                           AgentAction(id: UUID().uuidString, title: "Recusar", kind: "proposal.reject", arg: pid)]
        }
    }

    private func add(_ m: AgentMessage) { messages.append(m); store.append(m) }
    private func persist(_ id: String) { if let m = messages.first(where: { $0.id == id }) { store.update(m) } }
    private func edit(_ id: String, _ f: (inout AgentMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        f(&messages[i])
    }

    /// Virou o dia: a conversa da tela recomeça (o cérebro também abre sessão nova).
    private func rollDay() {
        let d = DailySummary.dayKey(Date())
        if d != day { day = d; messages = store.day(Date()) }
    }
}
