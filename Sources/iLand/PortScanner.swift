import Foundation

/// Uma porta aberta (TCP em LISTEN ou UDP com porta fixa) e o processo dono.
struct PortEntry: Identifiable, Equatable {
    let port: Int
    let proto: String      // "TCP" ou "UDP"
    let address: String    // "*", "127.0.0.1", "::1", "192.168.0.2"
    let exposed: Bool      // escuta além do loopback: acessível pela rede
    let pid: Int32
    let command: String    // nome que o lsof dá ao processo
    let uid: UInt32
    var id: String { "\(proto)\(port).\(pid)" }
}

/// Linha pronta para a aba Portas.
struct PortRow: Identifiable {
    let entry: PortEntry
    let name: String
    let note: String           // linha de comando curta, já mascarada (Redact)
    let age: TimeInterval?
    let target: ProcTarget?
    let canKill: Bool
    let links: [Origin.Link]   // o processo e os pais: acha o app com janela dono dele
    let tty: String
    var id: String { entry.id }
}

struct NetBytes: Equatable { var down: UInt64; var up: UInt64 }
struct AppNet: Equatable { let name: String; let down: Double; let up: Double }   // bytes/s

enum PortScanner {
    static let lsofArgs = ["-nP", "-w", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-F", "pcuPn"]
    static let nettopArgs = ["-P", "-L", "1", "-x", "-t", "external", "-J", "bytes_in,bytes_out"]

    /// Saída de `lsof -F pcuPn`: linhas "p<pid>", "c<nome>", "u<uid>", e por arquivo "f..", "P<TCP|UDP>", "n<endereço>".
    /// Ignora UDP sem porta (`*:*`) ou conectado (`a->b`) e linhas que não entende. Junta IPv4 e IPv6 da mesma porta e processo.
    static func parse(_ out: String) -> [PortEntry] {
        var pid: Int32?
        var cmd = "", uid = UInt32.max, proto = ""
        var byKey: [String: PortEntry] = [:]
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let v = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(v); cmd = ""; uid = .max; proto = ""
            case "c": cmd = v
            case "u": uid = UInt32(v) ?? .max
            case "f": proto = ""
            case "P": proto = v
            case "n":
                guard let p = pid, proto == "TCP" || proto == "UDP", let (host, port) = endpoint(v) else { continue }
                let e = PortEntry(port: port, proto: proto, address: host, exposed: !isLoopback(host), pid: p,
                                  command: cmd.isEmpty ? "processo \(p)" : cmd, uid: uid)
                if let old = byKey[e.id], old.exposed || !e.exposed { continue }   // fica o mais exposto
                byKey[e.id] = e
            default: continue
            }
        }
        return byKey.values.sorted { ($0.port, $0.proto, $0.pid) < ($1.port, $1.proto, $1.pid) }
    }

    /// "*:8080", "127.0.0.1:8765", "[::1]:3000" -> (host, porta). nil para conexão ("->") ou porta não numérica.
    static func endpoint(_ s: String) -> (String, Int)? {
        guard !s.contains("->"), let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]),
              (1...65535).contains(port) else { return nil }
        var host = String(s[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    /// `ps -o pid=,args=`: PID -> linha de comando.
    static func parseArgs(_ out: String) -> [Int32: String] {
        var r: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if f.count == 2, let pid = Int32(f[0]) { r[pid] = String(f[1]).trimmingCharacters(in: .whitespaces) }
        }
        return r
    }

    /// Tira o caminho do executável (o nome já aparece na linha) e mascara segredos.
    static func shortCommand(_ args: String, path: String) -> String {
        var a = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, a.hasPrefix(path) { a = a.dropFirst(path.count).trimmingCharacters(in: .whitespaces) }
        return Redact.command(a)
    }

    static func rows(_ entries: [PortEntry], args: [Int32: String], processes: [ProcSample], me: UInt32, myPid: Int32) -> [PortRow] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        // Seus servidores (python, node, mysqld...) primeiro; daemons do sistema depois; dentro de cada grupo, por porta.
        let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
        func isSystem(_ e: PortEntry) -> Bool { byPid[e.pid].map { p in systemPrefixes.contains { p.path.hasPrefix($0) } } ?? false }
        let ordered = entries.sorted { (isSystem($0) ? 1 : 0, $0.port, $0.proto, $0.pid) < (isSystem($1) ? 1 : 0, $1.port, $1.proto, $1.pid) }
        return ordered.map { e in
            let p = byPid[e.pid]
            var links = [Origin.Link(pid: e.pid, name: e.command)]
            var cur = p
            while links.count < 8, let c = cur, let parent = byPid[c.ppid], parent.pid > 1 {
                links.append(Origin.Link(pid: parent.pid, name: parent.name)); cur = parent
            }
            return PortRow(entry: e, name: p.map { $0.appName ?? $0.name } ?? e.command,
                           note: shortCommand(args[e.pid] ?? "", path: p?.path ?? ""), age: p?.elapsed, target: p?.target,
                           canKill: p.map { $0.uid == me && e.uid == me && !$0.isProtected && $0.pid != myPid } ?? false,
                           links: links, tty: p?.tty ?? "")
        }
    }

    // MARK: rede por app (nettop)

    /// `nettop -P -L 1 -x -J bytes_in,bytes_out`: "nome.pid,in,out," (nome cortado; o PID vem depois do último ".").
    static func parseNet(_ out: String) -> (bytes: [Int32: NetBytes], names: [Int32: String]) {
        var bytes: [Int32: NetBytes] = [:], names: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            var f = line.split(separator: ",", omittingEmptySubsequences: false)
            if f.last?.isEmpty == true { f.removeLast() }
            guard f.count >= 3, let up = UInt64(f[f.count - 1]), let down = UInt64(f[f.count - 2]) else { continue }
            let label = f.dropLast(2).joined(separator: ",")
            guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]) else { continue }
            bytes[pid] = NetBytes(down: down, up: up)
            names[pid] = String(label[..<dot])
        }
        return (bytes, names)
    }

    /// Taxa (bytes/s) entre duas leituras acumuladas. Só PIDs presentes nas duas; contador que voltou conta 0.
    static func rates(prev: [Int32: NetBytes], cur: [Int32: NetBytes], dt: TimeInterval) -> [Int32: NetBytes] {
        guard dt > 0 else { return [:] }
        var r: [Int32: NetBytes] = [:]
        for (pid, c) in cur {
            guard let p = prev[pid] else { continue }
            let d = c.down >= p.down ? c.down - p.down : 0, u = c.up >= p.up ? c.up - p.up : 0
            r[pid] = NetBytes(down: UInt64(Double(d) / dt), up: UInt64(Double(u) / dt))
        }
        return r
    }

    /// Soma por app com o critério da aba "Por app" (Chrome Helper conta para "Google Chrome"); some com quem fica abaixo
    /// de `minRate` bytes/s somando ↓ e ↑ (apareceria "0 KB/s").
    static func topApps(_ rates: [Int32: NetBytes], names: [Int32: String], processes: [ProcSample], limit: Int = 5, minRate: Double = 1024) -> [AppNet] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var sum: [String: (Double, Double)] = [:]
        for (pid, r) in rates where r.down + r.up > 0 {
            let name = byPid[pid].map { $0.appName ?? $0.name } ?? names[pid] ?? "processo \(pid)"
            let s = sum[name] ?? (0, 0)
            sum[name] = (s.0 + Double(r.down), s.1 + Double(r.up))
        }
        return sum.filter { $0.value.0 + $0.value.1 >= minRate }.map { AppNet(name: $0.key, down: $0.value.0, up: $0.value.1) }
            .sorted { ($0.down + $0.up, $1.name) > ($1.down + $1.up, $0.name) }
            .prefix(limit).map { $0 }
    }

    /// Roda um utilitário do sistema com argv separado (sem shell). Mata se passar de `timeout`.
    static func output(_ exe: String, _ args: [String], timeout: TimeInterval = 15, started: ((Process) -> Void)? = nil) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = args
        task.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        started?(task)
        let guardKill = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: guardKill)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guardKill.cancel()
        return String(data: data, encoding: .utf8)
    }
}

/// `lsof` e `nettop` (rede por app), cada um no máximo a cada 5 s (~0,03-0,07 s de CPU por rodada), fora da fila do
/// monitor. Quem chama garante que é só com a visão geral aberta na aba Portas; `stop()` mata o `nettop` em andamento.
final class PortsWatch {
    static let every: TimeInterval = 5
    private let lock = NSLock()
    private var scanning = false, lastScan = Date.distantPast
    private var netTask: Process?, netRunning = false, lastNet = Date.distantPast
    private var ports: (at: Date, list: [PortEntry], args: [Int32: String])?
    private var netPrev: (at: Date, bytes: [Int32: NetBytes])?
    private var net: (at: Date, rates: [Int32: NetBytes], names: [Int32: String])?

    func pollIfDue(now: Date) {
        lock.lock(); defer { lock.unlock() }
        if !scanning, now.timeIntervalSince(lastScan) >= Self.every {
            scanning = true; lastScan = now
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.scan() }
        }
        if !netRunning, now.timeIntervalSince(lastNet) >= Self.every {
            netRunning = true; lastNet = now
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.sampleNet() }
        }
    }

    func stop() {
        lock.lock(); netTask?.terminate(); lock.unlock()
    }

    /// Resultados com menos de 20 s (nil = ainda medindo).
    func latest(now: Date) -> (ports: (list: [PortEntry], args: [Int32: String])?, net: (rates: [Int32: NetBytes], names: [Int32: String])?) {
        lock.lock(); defer { lock.unlock() }
        let p = ports.flatMap { now.timeIntervalSince($0.at) < 20 ? ($0.list, $0.args) : nil }
        let n = net.flatMap { now.timeIntervalSince($0.at) < 20 ? ($0.rates, $0.names) : nil }
        return (p, n)
    }

    private func scan() {
        let list = PortScanner.parse(PortScanner.output("/usr/sbin/lsof", PortScanner.lsofArgs) ?? "")
        let pids = Set(list.map(\.pid)).map(String.init).joined(separator: ",")
        let args = pids.isEmpty ? [:] : PortScanner.parseArgs(PortScanner.output("/bin/ps", ["-o", "pid=,args=", "-p", pids]) ?? "")
        lock.lock(); ports = (Date(), list, args); scanning = false; lock.unlock()
    }

    private func sampleNet() {
        let out = PortScanner.output("/usr/bin/nettop", PortScanner.nettopArgs) { [weak self] t in
            self?.lock.lock(); self?.netTask = t; self?.lock.unlock()
        }
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        let ok = netTask?.terminationStatus == 0
        netTask = nil; netRunning = false
        guard ok, let out else { return }
        let cur = PortScanner.parseNet(out)
        if let prev = netPrev, now.timeIntervalSince(prev.at) < 20 {   // leitura antiga (aba reaberta) não vira taxa
            net = (now, PortScanner.rates(prev: prev.bytes, cur: cur.bytes, dt: now.timeIntervalSince(prev.at)), cur.names)
        }
        netPrev = (now, cur.bytes)
    }
}
