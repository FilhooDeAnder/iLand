import Foundation

/// Túneis SSH (`ssh -L`) cadastrados colando o comando que a pessoa já usa. Lógica pura, sem AppKit:
/// teste em Tests/Unit/test_tunnels.swift. Quem liga e desliga é o TunnelManager.
struct TunnelSpec: Codable, Equatable, Identifiable {
    struct Forward: Codable, Equatable {
        var local: Int
        var host: String
        var port: Int
    }
    var id = UUID()
    var name: String
    var host: String            // usuario@endereco
    var port: Int?
    var key: String?            // caminho da chave (-i), já sem "~"
    var forwards: [Forward]
    var autoStart = false       // ligar ao abrir o iLand

    /// "8011 → db.example.com:3306 · +2"
    var summary: String {
        guard let f = forwards.first else { return host }
        return "\(f.local) → \(f.host):\(f.port)" + (forwards.count > 1 ? " · +\(forwards.count - 1)" : "")
    }
}

enum TunnelCommand {
    struct Failure: Error, Equatable { let message: String }

    /// Lê um comando como `sudo ssh -L 8011:db:3306 -N -i "~/k.pem" user@host`.
    /// Só aceita -L, -i, -p e flags simples: o ssh roda como root, então nada de -o, -F, ProxyCommand ou comando remoto.
    static func parse(_ command: String, name: String) -> Result<TunnelSpec, Failure> {
        var t = split(command)
        while let first = t.first, first != "ssh", !first.hasSuffix("/ssh") { t.removeFirst() }   // sudo e as opções dele
        guard !t.isEmpty else { return .failure(Failure(message: "O comando precisa ter \"ssh\".")) }
        t.removeFirst()
        var host: String?, port: Int?, key: String?, forwards: [TunnelSpec.Forward] = []
        var i = 0
        func value(_ tok: String) -> String? {
            if tok.count > 2 { return String(tok.dropFirst(2)) }
            i += 1
            return i < t.count ? t[i] : nil
        }
        while i < t.count {
            let tok = t[i]
            if tok.hasPrefix("-L") {
                guard let v = value(tok), let f = forward(v) else { return .failure(Failure(message: "Não entendi um -L. Use porta:host:porta.")) }
                forwards.append(f)
            } else if tok.hasPrefix("-i") {
                guard let v = value(tok), !v.isEmpty else { return .failure(Failure(message: "Faltou o caminho da chave depois do -i.")) }
                key = (v as NSString).expandingTildeInPath
            } else if tok.hasPrefix("-p") {
                guard let v = value(tok), let p = Int(v), (1...65535).contains(p) else { return .failure(Failure(message: "Porta do -p inválida.")) }
                port = p
            } else if tok.hasPrefix("-") {
                let flags = tok.dropFirst()
                guard !flags.isEmpty, flags.allSatisfy({ "NfTnCqv".contains($0) }) else { return .failure(Failure(message: "Opção \(tok) não é aceita (só -L, -i, -p e -N).")) }
            } else if host == nil {
                guard isValidHost(tok) else { return .failure(Failure(message: "Endereço inválido: \(tok).")) }
                host = tok
            } else {
                return .failure(Failure(message: "Comando remoto depois do endereço não é aceito."))
            }
            i += 1
        }
        guard let host else { return .failure(Failure(message: "Faltou o endereço (usuario@servidor).")) }
        guard !forwards.isEmpty else { return .failure(Failure(message: "Faltou pelo menos um -L.")) }
        let n = name.trimmingCharacters(in: .whitespaces)
        return .success(TunnelSpec(name: n.isEmpty ? host : String(n.prefix(40)), host: host, port: port, key: key, forwards: forwards))
    }

    /// Argumentos do /usr/bin/sudo. Sem shell no meio: cada valor vai como um argumento só.
    static func arguments(_ s: TunnelSpec) -> [String] {
        var a = ["-A", "--", "/usr/bin/ssh", "-N",
                 "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                 "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
        if let p = s.port { a += ["-p", String(p)] }
        if let k = s.key { a += ["-i", k] }
        for f in s.forwards { a += ["-L", "\(f.local):\(f.host):\(f.port)"] }
        return a + ["--", s.host]
    }

    /// Espera depois da n-ésima queda seguida: 10, 20, 40, 80 e no máximo 120 s.
    static func retryDelay(_ n: Int) -> TimeInterval { min(10 * pow(2, Double(max(n, 1) - 1)), 120) }

    /// Última linha útil do stderr do ssh/sudo (avisos de host conhecido não contam).
    static func lastError(_ text: String) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("Warning:") }.map { String($0.prefix(120)) } ?? ""
    }

    /// "porta:host:porta" ou "endereco:porta:host:porta" (o endereço local é ignorado: o túnel só escuta no próprio Mac).
    static func forward(_ v: String) -> TunnelSpec.Forward? {
        let p = v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3 || p.count == 4 else { return nil }
        let r = Array(p.suffix(3))
        guard let l = Int(r[0]), let rp = Int(r[2]), (1...65535).contains(l), (1...65535).contains(rp),
              r[1].range(of: "^[A-Za-z0-9._-]{1,253}$", options: .regularExpression) != nil, !r[1].hasPrefix("-") else { return nil }
        return .init(local: l, host: r[1], port: rp)
    }

    static func isValidHost(_ h: String) -> Bool {
        h.range(of: "^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}(@[A-Za-z0-9._][A-Za-z0-9._-]{0,252})?$", options: .regularExpression) != nil
    }

    /// Divide como o shell: espaços separam, aspas simples e duplas agrupam, "\" escapa o próximo caractere.
    static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, escape = false, has = false
        for c in s {
            if escape { cur.append(c); escape = false; continue }
            if c == "\\" && quote != "'" { escape = true; has = true; continue }
            if let q = quote { if c == q { quote = nil } else { cur.append(c) }; continue }
            if c == "'" || c == "\"" { quote = c; has = true; continue }
            if c.isWhitespace { if has { out.append(cur); cur = ""; has = false }; continue }
            cur.append(c); has = true
        }
        if has { out.append(cur) }
        return out
    }
}

/// Lista salva nos Ajustes (JSON). Vazio = string vazia, para o Prefs esconder a página sem decodificar.
enum TunnelStore {
    static let key = "tunnels"
    static func load(_ d: UserDefaults = .standard) -> [TunnelSpec] {
        guard let s = d.string(forKey: key), let data = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TunnelSpec].self, from: data)) ?? []
    }
    static func save(_ list: [TunnelSpec], _ d: UserDefaults = .standard) {
        let s = list.isEmpty ? "" : (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        d.set(s, forKey: key)
    }
}
