// Uso: swiftc -parse-as-library Sources/iLand/SuspectTracker.swift Sources/iLand/PortScanner.swift Tests/Unit/test_ports.swift -o /tmp/t_ports && /tmp/t_ports
import Foundation

@main struct PortsCheck {
    static func main() {
        // Saída inventada de `lsof -F pcuPn`: IPv4+IPv6 da mesma porta, IPv6 só, UDP sem porta e conectado, linhas ruins.
        let out = """
        p100
        cnode
        u501
        f20
        PTCP
        n127.0.0.1:3000
        f21
        PTCP
        n[::1]:3000
        f22
        PTCP
        n*:8080
        f23
        PTCP
        n[::]:8080
        p200
        cPython
        u501
        f5
        PTCP
        n*:8765
        f6
        PUDP
        n*:*
        f7
        PUDP
        n192.168.0.2:5353->224.0.0.251:5353
        f8
        PUDP
        n*:5353
        p300
        cmysqld
        u74
        f9
        PTCP
        n127.0.0.1:3306
        f10
        PTCP
        n127.0.0.1:99999
        f11
        PTCP
        nlixo
        xcampo desconhecido

        p
        cquebrado
        f1
        PTCP
        n*:1234
        p400
        cnginx
        u501
        f3
        PTCP
        n192.168.0.10:8765
        """
        let e = PortScanner.parse(out)
        let keys = e.map { "\($0.proto)\($0.port)/\($0.pid)/\($0.exposed ? "rede" : "local")" }
        assert(keys == ["TCP3000/100/local", "TCP3306/300/local", "UDP5353/200/rede", "TCP8080/100/rede",
                        "TCP8765/200/rede", "TCP8765/400/rede"], "\(keys)")
        assert(e.first { $0.port == 3000 }?.address == "127.0.0.1", "IPv4 e IPv6 locais viram uma linha só")
        assert(e.first { $0.port == 3306 }?.uid == 74 && e.first { $0.port == 3306 }?.command == "mysqld")
        assert(!e.contains { $0.port == 1234 }, "linha sem PID é descartada")

        // IPv6 exposto depois do local: fica o exposto.
        let mixed = PortScanner.parse("p9\ncx\nu1\nf1\nPTCP\nn127.0.0.1:5000\nf2\nPTCP\nn[::]:5000\n")
        assert(mixed.count == 1 && mixed[0].exposed && mixed[0].address == "::")

        assert(PortScanner.endpoint("[::1]:3000")! == ("::1", 3000))
        assert(PortScanner.endpoint("*:8080")! == ("*", 8080))
        assert(PortScanner.endpoint("[fe80::1%lo0]:631")! == ("fe80::1%lo0", 631))
        assert(PortScanner.endpoint("*:*") == nil && PortScanner.endpoint(":80") == nil && PortScanner.endpoint("a:0") == nil)
        assert(PortScanner.isLoopback("127.0.0.1") && PortScanner.isLoopback("::1") && !PortScanner.isLoopback("*")
               && !PortScanner.isLoopback("0.0.0.0") && !PortScanner.isLoopback("::"))

        // Linha de comando curta, sem o caminho e sem segredo.
        let args = PortScanner.parseArgs("  200 /usr/bin/python3 -m http.server 8765 --token=abc123\n  100 node server.js\nlixo\n")
        assert(args[100] == "node server.js")
        assert(PortScanner.shortCommand(args[200]!, path: "/usr/bin/python3") == "-m http.server 8765 --token=•••", PortScanner.shortCommand(args[200]!, path: "/usr/bin/python3"))

        // Linhas da aba: idade e "Encerrar" só para processo meu e não protegido.
        let me: UInt32 = 501
        let procs = [
            ProcSample(pid: 100, ppid: 50, uid: me, cpu: 1, rssKB: 1, elapsed: 120, tty: "ttys001", path: "/opt/node"),
            ProcSample(pid: 50, ppid: 1, uid: me, cpu: 0, rssKB: 1, elapsed: 900, tty: "ttys001", path: "/bin/zsh"),
            ProcSample(pid: 300, ppid: 1, uid: 74, cpu: 0, rssKB: 1, elapsed: 60, tty: "", path: "/usr/local/mysqld"),
        ]
        let rows = PortScanner.rows(e, args: args, processes: procs, me: me, myPid: 1)
        let node = rows.first { $0.entry.port == 3000 }!
        assert(node.age == 120 && node.canKill && node.target?.pid == 100 && node.links.map(\.pid) == [100, 50] && node.tty == "ttys001")
        assert(rows.first { $0.entry.port == 3306 }!.canKill == false, "outro usuário: sem Encerrar")
        assert(rows.first { $0.entry.pid == 400 }!.canKill == false && rows.first { $0.entry.pid == 400 }!.age == nil, "sem amostra do ps: sem Encerrar")

        // Ordem: seus servidores primeiro, daemons do sistema depois; por porta dentro de cada grupo.
        let ord = [PortEntry(port: 3722, proto: "UDP", address: "*", exposed: true, pid: 901, command: "rapportd", uid: me),
                   PortEntry(port: 8765, proto: "TCP", address: "*", exposed: true, pid: 902, command: "Python", uid: me),
                   PortEntry(port: 53, proto: "TCP", address: "*", exposed: true, pid: 903, command: "mDNSResponder", uid: 0)]
        let ordProcs = [ProcSample(pid: 901, ppid: 1, uid: me, cpu: 0, rssKB: 1, elapsed: 1, tty: "", path: "/usr/libexec/rapportd"),
                        ProcSample(pid: 902, ppid: 1, uid: me, cpu: 0, rssKB: 1, elapsed: 1, tty: "", path: "/opt/homebrew/bin/Python"),
                        ProcSample(pid: 903, ppid: 1, uid: 0, cpu: 0, rssKB: 1, elapsed: 1, tty: "", path: "/usr/sbin/mDNSResponder")]
        assert(PortScanner.rows(ord, args: [:], processes: ordProcs, me: me, myPid: 1).map(\.entry.port) == [8765, 53, 3722], "\(PortScanner.rows(ord, args: [:], processes: ordProcs, me: me, myPid: 1).map(\.entry.port))")

        // nettop: nome cortado com "." e vírgula no nome; taxa entre duas leituras; agrupado por app.
        let n1 = PortScanner.parseNet(",bytes_in,bytes_out,\nGoogle Chrome H.10,1000,500,\nCursor Helper (.11,0,0,\napp.v2,x.12,10,10,\nquebrada\nsem.pid,1,2,\n")
        assert(n1.bytes[10] == NetBytes(down: 1000, up: 500) && n1.names[10] == "Google Chrome H")
        assert(n1.bytes[12] == NetBytes(down: 10, up: 10) && n1.names[12] == "app.v2,x" && n1.bytes.count == 3)
        let n2 = PortScanner.parseNet("Google Chrome H.10,11000,2500,\nCursor Helper (.11,0,0,\napp.v2,x.12,5,10,\nnovo.13,999,999,\n")
        let r = PortScanner.rates(prev: n1.bytes, cur: n2.bytes, dt: 2)
        assert(r[10] == NetBytes(down: 5000, up: 1000) && r[12] == NetBytes(down: 0, up: 0) && r[13] == nil, "\(r)")
        assert(PortScanner.rates(prev: n1.bytes, cur: n2.bytes, dt: 0).isEmpty)

        let chrome = [ProcSample(pid: 10, ppid: 1, uid: me, cpu: 0, rssKB: 1, elapsed: 1, tty: "",
                                 path: "/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
                      ProcSample(pid: 20, ppid: 1, uid: me, cpu: 0, rssKB: 1, elapsed: 1, tty: "", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")]
        let top = PortScanner.topApps([10: NetBytes(down: 1000, up: 0), 20: NetBytes(down: 500, up: 500), 30: NetBytes(down: 1100, up: 0),
                                       31: NetBytes(down: 0, up: 0), 32: NetBytes(down: 600, up: 400)], names: [30: "curl", 32: "parado"], processes: chrome)
        assert(top == [AppNet(name: "Google Chrome", down: 1500, up: 500), AppNet(name: "curl", down: 1100, up: 0)], "abaixo de 1 KB/s some: \(top)")
        let many = Dictionary(uniqueKeysWithValues: (1...9).map { (Int32($0), NetBytes(down: UInt64($0), up: 0)) })
        assert(PortScanner.topApps(many, names: [:], processes: [], minRate: 0).map(\.down) == [9, 8, 7, 6, 5], "no máximo 5, maior primeiro")

        print("ok")
    }
}
