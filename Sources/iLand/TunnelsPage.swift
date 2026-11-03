import SwiftUI
import Darwin

/// Liga e desliga os túneis. Cada túnel é um `sudo -A ssh -N -L ...` filho do iLand: a senha vem de um diálogo
/// (SUDO_ASKPASS) e o sudo lembra dela por ~5 min. Desligar = SIGTERM no sudo, que repassa ao ssh (sem senha).
/// Ligado e caiu: religa sozinho (10 s, dobrando até 120 s). Senha cancelada: desliga e avisa.
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
        procs.removeValue(forKey: id)?.terminate()
        states[id] = .off
        updateTimer()
    }

    func stopAll() { for id in wanted { stop(id) } }

    private func launch(_ id: UUID) {
        guard wanted.contains(id), procs[id] == nil, let s = specs.first(where: { $0.id == id }) else { return }
        if let f = s.forwards.first(where: { Self.listening($0.local) }) {
            return give(up: id, "Porta \(f.local) já em uso (o túnel já está ligado fora do iLand?)")
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
        if msg.hasPrefix("sudo:") { return give(up: id, "Senha não informada") }
        let n = (drops[id] ?? 0) + 1
        drops[id] = n
        let wait = TunnelCommand.retryDelay(n)
        states[id] = .failed((msg.isEmpty ? "Caiu" : msg) + " · tento de novo em \(Int(wait)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.launch(id) }
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
            let up = s.forwards.allSatisfy { Self.listening($0.local) }
            if up { states[id] = .on; drops[id] = 0 } else if states[id] == .on { states[id] = .connecting }
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

/// Uma linha por túnel: bolinha, nome, o que ele liga (ou o erro) e o liga/desliga.
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
        case .connecting: (.orange, "Conectando… · " + s.summary)
        case .on: (.green, s.summary)
        case .failed(let m): (.red, m)
        }
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(line).font(.system(size: 11)).foregroundColor(st == .off || st == .on ? secondary : color).lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { tunnels.isOn(s.id) }, set: { _ in tunnels.toggle(s.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.green)
        }
        .frame(height: 44)
    }
}

/// Cadastro: colar o comando ssh que já se usa. Sem túneis, a página some do notch.
struct TunnelsSettings: View {
    var manager: TunnelManager?
    @AppStorage(TunnelStore.key) private var json = ""   // só para redesenhar quando a lista muda
    @State private var name = ""
    @State private var command = ""

    var body: some View {
        let list = TunnelStore.load()
        let parsed = TunnelCommand.parse(command, name: name)
        SettingsPage(symbol: "point.3.connected.trianglepath.dotted", title: "Túneis",
                     subtitle: "Túneis SSH que você liga e desliga pelo notch. Sem túneis, a página some do notch.") {
            GlassSection("Cadastrados · \(list.count)") {
                if list.isEmpty { SettingRow("Nenhum túnel", detail: "A página Túneis fica escondida.", divider: false) { EmptyView() } }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    SettingRow(t.name, detail: "\(t.summary) · \(t.host)", divider: i < list.count - 1) {
                        HStack(spacing: 8) {
                            Toggle("Ligar ao abrir", isOn: Binding(get: { t.autoStart }, set: { v in
                                save(list.map { var x = $0; if x.id == t.id { x.autoStart = v }; return x })
                            })).toggleStyle(.checkbox)
                            Button("Remover") { save(list.filter { $0.id != t.id }) }.glassButton()
                        }
                    }
                }
            }
            GlassSection("Adicionar", footer: "Cole o comando que você já usa (pode ter sudo). O iLand aceita só -L, -i, -p e -N, roda com sudo e pede a senha de administrador ao ligar.") {
                SettingRow("Nome") { GlassField(placeholder: "ex.: Banco teste", text: $name, width: 220) }
                SettingRow("Comando") { GlassField(placeholder: "sudo ssh -L 8011:host:3306 -N -i chave.pem usuario@servidor", text: $command, width: 420) }
                SettingRow(command.isEmpty ? "Confira" : "Entendi", detail: detail(parsed), divider: false) {
                    Button("Adicionar") {
                        if case .success(let t) = parsed { save(list + [t]); name = ""; command = "" }
                    }.glassButton(prominent: true).disabled(!isSuccess(parsed))
                }
            }
        }
    }

    private func detail(_ r: Result<TunnelSpec, TunnelCommand.Failure>) -> String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        switch r {
        case .success(let t): return t.forwards.map { "\($0.local) → \($0.host):\($0.port)" }.joined(separator: ", ") + " por " + t.host
        case .failure(let f): return f.message
        }
    }

    private func isSuccess(_ r: Result<TunnelSpec, TunnelCommand.Failure>) -> Bool { if case .success = r { true } else { false } }

    private func save(_ list: [TunnelSpec]) {
        if let manager { manager.save(list) } else { TunnelStore.save(list) }
        json = UserDefaults.standard.string(forKey: TunnelStore.key) ?? ""
    }
}
