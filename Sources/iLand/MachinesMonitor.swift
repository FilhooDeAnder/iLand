import AppKit
import Combine

struct MachineEntry: Identifiable {
    let alias: String
    var status: MachineStatus?
    var state: MachineState = .unknown
    var explanation = ""
    var explaining = false
    var id: String { alias }
}

struct MachineNotice { let alias: String; let level: MachineLevel; let text: String }

/// Consulta CPU, RAM, swap e disco de cada máquina Linux por SSH a cada 5 min (comandos de leitura, nada instalado lá),
/// guarda 7 dias de histórico e avisa quando piora. Nunca escreve nem reinicia nada nas máquinas.
final class MachinesMonitor: ObservableObject {
    @Published private(set) var entries: [MachineEntry]
    @Published var holdOpen = false        // vermelho abriu o notch: não recolhe sozinho (clique fora fecha)
    @Published var focus: String?          // máquina aberta no detalhe da página
    let notices = PassthroughSubject<MachineNotice, Never>()
    private var gate = MachineAlertGate()
    private var timer: Timer?
    private var lastPrune = Date.distantPast
    static let interval: TimeInterval = 300

    /// Começa com a última leitura boa salva em disco, para a página não ficar vazia até o primeiro SSH responder.
    init(aliases: [String] = Prefs.machines) {
        entries = aliases.map { a in
            var e = MachineEntry(alias: a)
            e.status = HistoryFile.loadLast(a)
            return e
        }
    }

    var issueCount: Int { entries.filter { $0.state.alertLevel > .ok }.count }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 30
        timer = t
    }

    func refresh() {
        for e in entries {
            let alias = e.alias
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let data = Self.fetch(alias)
                DispatchQueue.main.async { self?.apply(alias, data, now: Date()) }
            }
        }
    }

    /// `ssh -o BatchMode=yes … <alias> <comando fixo>`: argumentos separados, sem shell local; 90 s no máximo
    /// (o bastion leva ~30 s para abrir a conexão).
    static func fetch(_ alias: String) -> Data? {
        guard Prefs.machines.contains(alias) else { return nil }
        return ssh(alias)
    }

    /// Teste de Ajustes, antes de adicionar a máquina.
    static func probe(_ host: String) -> MachineStatus? {
        guard Prefs.isValidHost(host), let d = ssh(host) else { return nil }
        return MachineStatus.parse(String(decoding: d, as: UTF8.self))
    }

    private static func ssh(_ alias: String) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=60", "-o", "ServerAliveInterval=5", "--", alias, MachineStatus.remoteCommand]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { if task.isRunning { task.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile().prefix(1_000_000)
        task.waitUntilExit()
        return task.terminationStatus == 0 ? Data(data) : nil
    }

    func apply(_ alias: String, _ data: Data?, now: Date) {
        guard let i = entries.firstIndex(where: { $0.alias == alias }) else { return }
        let status = data.flatMap { MachineStatus.parse(String(decoding: $0, as: UTF8.self)) }
        let st = MachineRules.state(status, now: now, previous: entries[i].state)
        if let status, let data {
            entries[i].status = status
            HistoryFile.append(alias, MachineHistory.line(status, now: now))
            HistoryFile.saveLast(alias, data)
        }
        entries[i].state = st
        if let lv = gate.update(alias, st, now: now) {
            let text = MachineRules.headline(st, entries[i].status, now: now)
            notices.send(MachineNotice(alias: alias, level: lv, text: text))
        }
        if now.timeIntervalSince(lastPrune) > 86400 { lastPrune = now; for e in entries { HistoryFile.prune(e.alias, now: now) } }
    }

    /// Manda ao Claude só o apelido e os números (CPU, RAM, swap, disco, tempo ligada).
    func explain(_ alias: String) {
        guard let i = entries.firstIndex(where: { $0.alias == alias }), !entries[i].explaining, let s = entries[i].status else { return }
        entries[i].explaining = true; entries[i].explanation = ""
        let prompt = """
        Máquina "\(alias)" (EC2 pequena, Amazon Linux 2023): CPU \(s.cpuPct)% (\(s.cpus) núcleos), RAM \(s.ramPct)% de \(s.memTotalKb / 1024) MB, swap \(s.swapPct)%, disco \(s.diskPct)%, ligada há \(Int(s.uptimeS / 86400)) dias.
        Problemas: \(s.problems.map(\.text).joined(separator: "; ")).
        Diga a causa provável e o que conferir agora, em até 5 linhas. Só leitura: sugira comandos, não execute nada.
        """
        LLM.ask(prompt, role: .explain) { [weak self] text in
            guard let self, let j = self.entries.firstIndex(where: { $0.alias == alias }) else { return }
            self.entries[j].explanation = text; self.entries[j].explaining = false
        }
    }

    /// Abre o terminal da pessoa já em `ssh <alias>`.
    func openSSH(_ alias: String) { if Prefs.machines.contains(alias) { Terminal.ssh(alias) } }

    /// A lista mudou nos Ajustes: mantém o que já foi lido das máquinas que ficaram e começa ou para a consulta.
    func reload() {
        let old = Dictionary(uniqueKeysWithValues: entries.map { ($0.alias, $0) })
        entries = Prefs.machines.map { a in
            if let e = old[a] { return e }
            var e = MachineEntry(alias: a); e.status = HistoryFile.loadLast(a); return e
        }
        if entries.isEmpty { timer?.invalidate(); timer = nil } else if timer == nil { start() } else { refresh() }
    }

    /// Depuração (ILAND_MACHINES_DEMO=1): três máquinas inventadas, uma em cada nível, sem SSH.
    func loadDemo() {
        func demo(avail: Int, disk: Int) -> Data {
            Data("0.40 0.30 0.20 1/160 1\n2\n360000 1\nMemTotal: 460000 kB\nMemAvailable: \(avail) kB\nSwapTotal: 2097148 kB\nSwapFree: 1900000 kB\n/dev/x 1 1 1 \(disk)% /\n".utf8)
        }
        let samples = [demo(avail: 200_000, disk: 41), demo(avail: 120_000, disk: 84), demo(avail: 260_000, disk: 37)]   // um amarelo, sem vermelho (vermelho abre o detalhe sozinho)
        for (e, d) in zip(entries, samples) { apply(e.alias, d, now: Date()) }
    }

    /// Histórico em ~/Library/Application Support/iLand/machines/<alias>.jsonl (pasta 0700, arquivo 0600).
    enum HistoryFile {
        static var dir: URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let d = base.appendingPathComponent("iLand/machines", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return d
        }
        static func file(_ alias: String) -> URL { dir.appendingPathComponent("\(alias).jsonl") }

        static func append(_ alias: String, _ line: String) {
            let url = file(alias)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data((line + "\n").utf8))
        }

        /// Saída crua do último SSH bom em <alias>.last (0600).
        static func saveLast(_ alias: String, _ data: Data) {
            let url = dir.appendingPathComponent("\(alias).last")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        static func loadLast(_ alias: String) -> MachineStatus? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(alias).last")) else { return nil }
            return MachineStatus.parse(String(decoding: data, as: UTF8.self))
        }

        static func prune(_ alias: String, now: Date) {
            let url = file(alias)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let kept = MachineHistory.prune(text.split(separator: "\n").map(String.init), now: now)
            try? Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
