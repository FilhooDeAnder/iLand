import SwiftUI
import Darwin

/// Liga e desliga os serviços: túneis e comandos locais.
/// Túnel = `sudo -A ssh -N -L ...` filho do iLand: a senha vem de um diálogo (SUDO_ASKPASS) e o sudo lembra dela
/// por ~5 min. Desligar = SIGTERM no sudo, que repassa ao ssh (sem senha). Caiu: religa sozinho (10 s, dobrando até 120 s).
/// Comando = `zsh -lc <comando>` na pasta cadastrada, como você. Desligar = SIGTERM nele e nos filhos. Parou sozinho: avisa, não religa.
final class TunnelManager: ObservableObject {
    enum State: Equatable { case off, connecting, on, failed(String) }

    @Published private(set) var specs: [TunnelSpec] = TunnelStore.load()
    @Published private(set) var states: [UUID: State] = [:]
    private var procs: [UUID: Process] = [:]
    private var wanted: Set<UUID> = []
    private var drops: [UUID: Int] = [:]
    private var timer: Timer?

    func state(_ id: UUID) -> State { states[id] ?? .off }
    func isOn(_ id: UUID) -> Bool { wanted.contains(id) }

    func reload() {
        specs = TunnelStore.load()
        for id in wanted where !specs.contains(where: { $0.id == id }) { stop(id) }
    }

    func save(_ list: [TunnelSpec]) { TunnelStore.save(list); reload() }

    /// ILAND_DEMO: túneis inventados no lugar dos cadastrados (nada é salvo), o primeiro ligado, sem rodar nada.
    func loadDemo() {
        specs = Demo.tunnels
        if let a = specs.first { wanted.insert(a.id); states[a.id] = .on }
    }

    func startAutos() { for s in specs where s.autoStart { start(s.id) } }

    func toggle(_ id: UUID) { wanted.contains(id) ? stop(id) : start(id) }

    func start(_ id: UUID) {
        guard specs.contains(where: { $0.id == id }) else { return }
        wanted.insert(id); drops[id] = 0
        launch(id)
    }

    func stop(_ id: UUID) {
        wanted.remove(id)
        if let p = procs.removeValue(forKey: id) { Self.killTree(p.processIdentifier) }
        states[id] = .off
        updateTimer()
    }

    func stopAll() { for id in wanted { stop(id) } }

    private func launch(_ id: UUID) {
        guard wanted.contains(id), procs[id] == nil, let s = specs.first(where: { $0.id == id }) else { return }
        if let port = ServiceCommand.ports(s).first(where: Self.listening) {
            return give(up: id, "Porta \(port) já em uso (já está ligado fora do iLand?)")
        }
        if s.isCommand {
            let p = Self.spawn(s) { [weak self] proc, msg in DispatchQueue.main.async { self?.ended(id, proc, msg) } }
            guard let p else { return give(up: id, "Não consegui rodar o comando") }
            procs[id] = p
            states[id] = .connecting
            return updateTimer()
        }
        if let k = s.key, !FileManager.default.fileExists(atPath: k) { return give(up: id, "Chave não encontrada: \(k)") }
        guard let askpass = Self.askpass() else { return give(up: id, "Não consegui criar o pedido de senha") }
        let p = Process(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = TunnelCommand.arguments(s)
        var env = ProcessInfo.processInfo.environment
        env["SUDO_ASKPASS"] = askpass; env["ILAND_TUNNEL"] = s.name
        p.environment = env
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = err
        p.terminationHandler = { [weak self] proc in
            let msg = TunnelCommand.lastError(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            DispatchQueue.main.async { self?.ended(id, proc, msg) }
        }
        do { try p.run() } catch { return give(up: id, "Não abriu o sudo: \(error.localizedDescription)") }
        procs[id] = p
        if states[id] != .on { states[id] = .connecting }
        updateTimer()
    }

    private func ended(_ id: UUID, _ proc: Process, _ msg: String) {
        guard procs[id] === proc else { return }
        procs[id] = nil
        guard wanted.contains(id) else { states[id] = .off; return }
        if specs.first(where: { $0.id == id })?.isCommand == true {
            wanted.remove(id)
            states[id] = proc.terminationStatus == 0 ? .off : .failed(msg.isEmpty ? "Parou (código \(proc.terminationStatus))" : msg)
            return updateTimer()
        }
        if msg.hasPrefix("sudo:") { return give(up: id, "Senha não informada") }
        let n = (drops[id] ?? 0) + 1
        drops[id] = n
        let wait = TunnelCommand.retryDelay(n)
        let again = " · tento de novo em \(Int(wait)) s"
        states[id] = .failed((msg.isEmpty ? "Caiu" : msg) + again)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.launch(id) }
        // Timeout no ssh: quase sempre o IP de casa mudou e não está liberado no servidor. Mostra qual IP liberar.
        if TunnelCommand.isTimeout(msg) {
            Self.publicIP { [weak self] ip in
                guard let self, case .failed = self.states[id] ?? .off, self.wanted.contains(id) else { return }
                self.states[id] = .failed("SSH sem resposta: libere o IP \(ip ?? "deste Mac") no servidor" + again)
            }
        }
    }

    /// IP público deste Mac (o que o servidor vê). Só é consultado quando o ssh dá timeout.
    private static func publicIP(_ done: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://checkip.amazonaws.com")!)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let ip = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = ip.map { $0.range(of: "^[0-9a-fA-F.:]{3,45}$", options: .regularExpression) != nil } ?? false
            DispatchQueue.main.async { done(ok ? ip : nil) }
        }.resume()
    }

    private func give(up id: UUID, _ msg: String) {
        wanted.remove(id)
        states[id] = .failed(msg)
        updateTimer()
    }

    /// Verde só quando todas as portas locais aceitam conexão (o ssh já autenticou e abriu o -L).
    private func updateTimer() {
        if procs.isEmpty { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        for (id, _) in procs {
            guard let s = specs.first(where: { $0.id == id }) else { continue }
            let up = ServiceCommand.ports(s).allSatisfy { Self.listening($0) }
            if up { states[id] = .on; drops[id] = 0 } else if states[id] == .on { states[id] = .connecting }
        }
    }

    /// Roda o comando na pasta dele, com o zsh de login (mesmo PATH do Terminal). Guarda só o fim da saída (para o erro)
    /// e lê o tempo todo: com o pipe cheio, o servidor travaria ao escrever.
    static func spawn(_ s: TunnelSpec, ended: @escaping (Process, String) -> Void) -> Process? {
        guard let cmd = s.command else { return nil }
        let p = Process(), out = Pipe(), tail = Tail()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: s.folder ?? NSHomeDirectory())
        p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = out
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { tail.append(d) }
        }
        p.terminationHandler = { proc in ended(proc, TunnelCommand.lastError(tail.text)) }
        do { try p.run() } catch { return nil }
        return p
    }

    /// SIGTERM no processo e em todos os filhos (o zsh pode ter criado o python como filho).
    static func killTree(_ pid: pid_t) {
        guard pid > 0 else { return }
        var kids = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &kids, Int32(kids.count * MemoryLayout<pid_t>.size))
        for k in kids.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size) where k > 0 { killTree(k) }
        kill(pid, SIGTERM)
    }

    /// Botão Testar dos Ajustes: roda o comando por até 8 s, sem cadastrar. Responde assim que a porta do link
    /// atende, ou se o comando parar; senão, "ainda rodando" (bom sinal para um servidor). Depois desliga.
    static func trial(_ s: TunnelSpec, done: @escaping (Bool, String) -> Void) {
        if let port = ServiceCommand.ports(s).first(where: listening) { return done(false, "A porta \(port) já está em uso.") }
        var finished = false
        func finish(_ ok: Bool, _ msg: String) { if !finished { finished = true; done(ok, msg) } }
        guard let p = spawn(s, ended: { proc, msg in
            DispatchQueue.main.async {
                finish(proc.terminationStatus == 0, proc.terminationStatus == 0 ? "Rodou e terminou sem erro." : (msg.isEmpty ? "Parou com código \(proc.terminationStatus)." : "Parou: \(msg)"))
            }
        }) else { return done(false, "Não consegui rodar o comando.") }
        let port = ServiceCommand.localPort(s.url)
        for i in 1...16 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                guard !finished else { return }
                if let port, listening(port) { finish(true, "Funcionou: a porta \(port) respondeu."); killTree(p.processIdentifier) }
                else if i == 16 {
                    finish(port == nil, port == nil ? "Ainda rodando depois de 8 s: parece certo." : "Rodou 8 s, mas a porta \(port!) não respondeu.")
                    killTree(p.processIdentifier)
                }
            }
        }
    }

    /// Algo aceita conexão em 127.0.0.1:porta?
    static func listening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(UInt16(port).bigEndian); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    /// Script do SUDO_ASKPASS: diálogo do macOS com a senha escondida. Pasta e arquivo só do usuário.
    private static func askpass() -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLand")
        let f = dir.appendingPathComponent("tunnel-askpass")
        let script = """
        #!/bin/sh
        exec /usr/bin/osascript -e 'text returned of (display dialog ("Senha de administrador do Mac para ligar o túnel " & (system attribute "ILAND_TUNNEL") & ".") default answer "" with hidden answer with title "iLand" with icon caution)'

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? String(contentsOf: f, encoding: .utf8)) != script { try script.write(to: f, atomically: true, encoding: .utf8) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
            return f.path
        } catch { return nil }
    }
}

/// Fim da saída de um comando (até 4 KB), escrito pela fila do pipe e lido na do término.
final class Tail: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); if data.count > 4096 { data = data.suffix(4096) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Uma linha por serviço: bolinha, nome, o que ele liga (ou o erro), o botão do link (ligado) e o liga/desliga.
struct TunnelsPage: View {
    @ObservedObject var tunnels: TunnelManager

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(tunnels.specs) { row($0) }
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 18)
        .padding(.top, NotchLayout.ear)
        .padding(.bottom, 16)
    }

    private func row(_ s: TunnelSpec) -> some View {
        let st = tunnels.state(s.id)
        let (color, line): (Color, String) = switch st {
        case .off: (.gray, s.summary)
        case .connecting: (.orange, (s.isCommand ? "Iniciando… · " : "Conectando… · ") + s.summary)
        case .on: (.green, s.summary)
        case .failed(let m): (.red, m)
        }
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(line).font(.system(size: 11)).foregroundColor(st == .off || st == .on ? secondary : color).lineLimit(1).help(line)
            }
            Spacer(minLength: 8)
            if st == .on, let link = s.url.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(link) } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 15)).foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain).help("Abrir \(link.absoluteString)")
            }
            Toggle("", isOn: Binding(get: { tunnels.isOn(s.id) }, set: { _ in tunnels.toggle(s.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.green)
        }
        .frame(height: 44)
    }
}

/// Cadastro: comando local (pasta + comando + link) ou túnel (colar o comando ssh). Sem nenhum, a página some do notch.
struct TunnelsSettings: View {
    var manager: TunnelManager?
    @AppStorage(TunnelStore.key) private var json = ""   // só para redesenhar quando a lista muda
    @State private var kind = 0                            // 0 comando, 1 túnel
    @State private var name = ""
    @State private var command = ""
    @State private var folder = ""
    @State private var link = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        let list = TunnelStore.load()
        let parsed = kind == 0 ? ServiceCommand.make(name: name, folder: folder, command: command, url: link) : TunnelCommand.parse(command, name: name)
        SettingsPage(symbol: "server.rack", title: "Serviços",
                     subtitle: "Comandos e túneis SSH que ficam rodando, ligados e desligados pelo notch. Sem nenhum, a página some do notch.") {
            GlassSection("Cadastrados · \(list.count)") {
                if list.isEmpty { SettingRow("Nenhum serviço", detail: "A página Serviços fica escondida.", divider: false) { EmptyView() } }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    SettingRow(t.name, detail: t.isCommand ? "\(t.summary) · \((t.folder ?? "") as NSString).abbreviatingWithTildeInPath)" : "\(t.summary) · \(t.host)",
                               divider: i < list.count - 1) {
                        HStack(spacing: 8) {
                            Toggle("Ligar ao abrir", isOn: Binding(get: { t.autoStart }, set: { v in
                                save(list.map { var x = $0; if x.id == t.id { x.autoStart = v }; return x })
                            })).toggleStyle(.checkbox)
                            Button("Remover") { save(list.filter { $0.id != t.id }) }.glassButton()
                        }
                    }
                }
            }
            GlassSection("Adicionar", footer: kind == 0
                         ? "O comando roda como você, na pasta escolhida, com o mesmo PATH do Terminal. Com link de localhost, a bolinha fica verde quando a porta responde."
                         : "Cole o comando que você já usa (pode ter sudo). O iLand aceita só -L, -i, -p e -N, roda com sudo e pede a senha de administrador ao ligar.") {
                SettingRow("Tipo") {
                    Picker("", selection: $kind) { Text("Comando").tag(0); Text("Túnel SSH").tag(1) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                SettingRow("Nome") { GlassField(placeholder: kind == 0 ? "ex.: Security viewer" : "ex.: Banco teste", text: $name, width: 220) }
                if kind == 0 {
                    SettingRow("Pasta") {
                        HStack(spacing: 8) {
                            GlassField(placeholder: "~/projeto/pasta", text: $folder, width: 320)
                            Button("Escolher…") { pickFolder() }.glassButton()
                        }
                    }
                    SettingRow("Comando") { GlassField(placeholder: "python3 server.py", text: $command, width: 420) }
                    SettingRow("Link (opcional)") { GlassField(placeholder: "http://localhost:8038/pagina.html", text: $link, width: 420) }
                } else {
                    SettingRow("Comando") { GlassField(placeholder: "sudo ssh -L 8011:host:3306 -N -i chave.pem usuario@servidor", text: $command, width: 420) }
                }
                SettingRow(testResult.map { $0.ok ? "Teste ok" : "Teste falhou" } ?? (command.isEmpty ? "Confira" : "Entendi"),
                           detail: testResult?.text ?? detail(parsed), divider: false) {
                    HStack(spacing: 8) {
                        if kind == 0 {
                            Button(testing ? "Testando…" : "Testar") { test(parsed) }.glassButton().disabled(testing || !isSuccess(parsed))
                        }
                        Button("Adicionar") {
                            if case .success(let t) = parsed { save(list + [t]); name = ""; command = ""; folder = ""; link = ""; testResult = nil }
                        }.glassButton(prominent: true).disabled(!isSuccess(parsed))
                    }
                }
            }
            .onChange(of: command) { _ in testResult = nil }
            .onChange(of: folder) { _ in testResult = nil }
            .onChange(of: link) { _ in testResult = nil }
            .onChange(of: kind) { _ in testResult = nil }
        }
    }

    private func detail(_ r: Result<TunnelSpec, TunnelCommand.Failure>) -> String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        switch r {
        case .success(let t) where t.isCommand: return "Roda \"\(t.summary)\" em \(((t.folder ?? "") as NSString).abbreviatingWithTildeInPath)"
        case .success(let t): return t.forwards.map { "\($0.local) → \($0.host):\($0.port)" }.joined(separator: ", ") + " por " + t.host
        case .failure(let f): return f.message
        }
    }

    private func isSuccess(_ r: Result<TunnelSpec, TunnelCommand.Failure>) -> Bool { if case .success = r { true } else { false } }

    private func test(_ r: Result<TunnelSpec, TunnelCommand.Failure>) {
        guard case .success(let t) = r else { return }
        testing = true; testResult = nil
        TunnelManager.trial(t) { ok, msg in testing = false; testResult = (ok, msg) }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { folder = (u.path as NSString).abbreviatingWithTildeInPath }
    }

    private func save(_ list: [TunnelSpec]) {
        if let manager { manager.save(list) } else { TunnelStore.save(list) }
        json = UserDefaults.standard.string(forKey: TunnelStore.key) ?? ""
    }
}
