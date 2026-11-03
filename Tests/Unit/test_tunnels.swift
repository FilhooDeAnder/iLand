// Uso: swiftc -parse-as-library Sources/iLand/Tunnels.swift Tests/Unit/test_tunnels.swift -o /tmp/t_tunnels && /tmp/t_tunnels
import Foundation

@main struct TunnelsCheck {
    static func main() {
        let cmd = #"sudo ssh -L 8011:db.example.com:3306    -L 8009:writer.example.com:3306 -N  -i "~/My Keys/a.pem" ana@ec2-1-2-3-4.example.com"#
        guard case .success(let t) = TunnelCommand.parse(cmd, name: " Banco ") else { fatalError("comando válido recusado") }
        assert(t.name == "Banco" && t.host == "ana@ec2-1-2-3-4.example.com" && t.port == nil)
        assert(t.key == NSHomeDirectory() + "/My Keys/a.pem")
        assert(t.forwards == [.init(local: 8011, host: "db.example.com", port: 3306), .init(local: 8009, host: "writer.example.com", port: 3306)])
        assert(t.summary == "8011 → db.example.com:3306 · +1")

        // Formas coladas: -L junto, -p, endereço local no -L, flags agrupadas, sem nome.
        guard case .success(let u) = TunnelCommand.parse("ssh -NT -p 2222 -L127.0.0.1:5432:pg:5432 host-1", name: "") else { fatalError() }
        assert(u.name == "host-1" && u.port == 2222 && u.forwards == [.init(local: 5432, host: "pg", port: 5432)])

        // Recusados: roda como root, então nada além de -L/-i/-p/flags.
        for bad in ["ssh -o ProxyCommand=sh host -L 1:a:2", "ssh -L 1:a:2 host rm -rf /", "ssh -L 1:a:2", "ssh host",
                    "ssh -L 99999:a:1 host", "ssh -L 1:-oX:2 host", "ssh -L 1:a:2 -- -oX", "ssh -F cfg -L 1:a:2 host", "ls -L 1:a:2 h", ""] {
            if case .success = TunnelCommand.parse(bad, name: "") { fatalError("deveria recusar: \(bad)") }
        }

        let args = TunnelCommand.arguments(t)
        assert(Array(args.prefix(3)) == ["-A", "--", "/usr/bin/ssh"] && args.suffix(2) == ["--", t.host])
        assert(args.contains("8009:writer.example.com:3306") && args.contains(t.key!) && !args.contains("-p"))

        assert(TunnelCommand.retryDelay(1) == 10 && TunnelCommand.retryDelay(3) == 40 && TunnelCommand.retryDelay(9) == 120)
        assert(TunnelCommand.lastError("Warning: Permanently added x\nbind [127.0.0.1]:8011: Address already in use\n") == "bind [127.0.0.1]:8011: Address already in use")

        assert(TunnelCommand.isTimeout("ssh: connect to host ec2-1-2-3-4.example.com port 22: Operation timed out"))
        assert(TunnelCommand.isTimeout("ssh: connect to host h port 22: Connection timed out") && !TunnelCommand.isTimeout("Permission denied (publickey)."))

        let d = UserDefaults(suiteName: "test-tunnels-\(getpid())")!
        TunnelStore.save([t, u], d)
        assert(TunnelStore.load(d) == [t, u])
        TunnelStore.save([], d)
        assert(d.string(forKey: TunnelStore.key) == "" && TunnelStore.load(d).isEmpty)
        // Comandos locais: pasta precisa existir, link só http(s), porta do link local vira o teste de "ligado".
        guard case .success(let c) = ServiceCommand.make(name: "", folder: "~", command: " python3 server.py ", url: "http://localhost:8038/x.html") else { fatalError() }
        assert(c.isCommand && c.command == "python3 server.py" && c.folder == NSHomeDirectory() && c.summary == "python3 server.py")
        assert(ServiceCommand.ports(c) == [8038] && ServiceCommand.ports(t) == [8011, 8009])
        assert(ServiceCommand.localPort("http://example.com:8038") == nil && ServiceCommand.localPort("http://127.0.0.1") == 80)
        for (f, cmd, u) in [("~", "", ""), ("/nao/existe", "ls", ""), ("~", "ls", "ftp://x"), ("~", "ls", "localhost:80")] {
            if case .success = ServiceCommand.make(name: "", folder: f, command: cmd, url: u) { fatalError("deveria recusar: \(f) \(cmd) \(u)") }
        }
        // JSON antigo (sem os campos novos) continua abrindo.
        let old = #"[{"id":"9C2A3F51-0D35-4E8B-9F7E-0A1B2C3D4E5F","name":"A","host":"h","forwards":[{"local":1,"host":"a","port":2}],"autoStart":false}]"#
        d.set(old, forKey: TunnelStore.key)
        assert(TunnelStore.load(d).first?.command == nil && TunnelStore.load(d).count == 1)
        TunnelStore.save([c], d)
        assert(TunnelStore.load(d) == [c])
        print("ok")
    }
}
