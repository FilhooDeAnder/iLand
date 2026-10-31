import Foundation

struct ProcSample: Identifiable, Equatable {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let cpu: Double
    let rssKB: Int
    let elapsed: TimeInterval
    let tty: String       // "ttys003" ou "" se não tem terminal
    let path: String
    var startedAt = Date()  // hora de início do processo (identidade junto com o caminho; PID sozinho pode ser reutilizado)

    var id: Int32 { pid }
    var name: String { (path as NSString).lastPathComponent }
    /// Nome do app mais externo (Chrome Helper dentro de Google Chrome.app -> "Google Chrome").
    var appName: String? {
        for part in path.split(separator: "/") where part.hasSuffix(".app") { return String(part.dropLast(4)) }
        return nil
    }
}

/// Quem vamos encerrar: PID + caminho + hora de início. Antes de cada sinal conferimos se o PID ainda é este processo.
struct ProcTarget {
    let pid: Int32
    let path: String
    let startedAt: Date

    func matches(path p: String, startedAt s: Date) -> Bool { p == path && abs(s.timeIntervalSince(startedAt)) < 5 }
}

/// Esconde segredos comuns em linhas de comando (aparecem no notch e em screenshots).
enum Redact {
    private static let rules: [(String, String)] = [
        (#"(?i)(--?[a-z0-9_-]*(?:token|password|passwd|secret|api[-_]?key|apikey|auth|credential|cookie)[a-z0-9_-]*)(=|\s+)\S+"#, "$1$2•••"),
        (#"(?i)\b([a-z0-9_]*(?:token|password|passwd|secret|api[-_]?key|apikey|credential)[a-z0-9_]*)=\S+"#, "$1=•••"),
        (#"(?i)\bbearer\s+\S+"#, "Bearer •••"),
        (#"\bsk-[A-Za-z0-9_-]{8,}"#, "sk-•••"),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "gh_•••"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "AKIA•••"),
        (#"://[^/\s:@]+:[^/\s@]+@"#, "://•••@"),
    ]

    /// Além dos de comando: e-mail, JWT e números longos (CPF, cartão, telefone). Para títulos de janela, erros e pedidos.
    private static let textRules: [(String, String)] = [
        (#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, "[jwt]"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+"#, "[email]"),
        (#"\d{9,}"#, "[nº]"),
    ]

    static func command(_ s: String) -> String {
        rules.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }

    static func text(_ s: String) -> String {
        textRules.reduce(command(s)) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }
}

extension ProcSample {
    var target: ProcTarget { ProcTarget(pid: pid, path: path, startedAt: startedAt) }
    /// Processos que nunca oferecemos para encerrar.
    var isProtected: Bool {
        pid <= 1 || ["kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer"].contains(name)
    }
}

struct Suspect: Identifiable {
    let sample: ProcSample
    let hint: String      // só casos especiais (automação, sem pai)
    let chain: [Origin.Link]  // quem iniciou: pai, avô, ... (mais próximo primeiro)
    let command: String   // linha de comando completa
    let canKill: Bool
    var id: Int32 { sample.pid }
}

/// Marca como suspeito o processo que fica acima do limite de CPU por tempo seguido.
struct SuspectTracker {
    var cpuThreshold = 80.0
    var resetBelow = 50.0
    var sustained: TimeInterval = 300
    private var highSince: [Int32: Date] = [:]

    mutating func update(_ samples: [ProcSample], now: Date) -> Set<Int32> {
        var live = Set<Int32>()
        var hot = Set<Int32>()
        for s in samples {
            live.insert(s.pid)
            if s.cpu >= cpuThreshold {
                if highSince[s.pid] == nil { highSince[s.pid] = now }
            } else if s.cpu < resetBelow {
                highSince[s.pid] = nil
            }
            if let since = highSince[s.pid], now.timeIntervalSince(since) >= sustained { hot.insert(s.pid) }
        }
        highSince = highSince.filter { live.contains($0.key) }
        return hot
    }
}

enum Origin {
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/"]

    struct Link: Equatable {
        let pid: Int32
        let name: String
    }

    /// `ancestors`: pai, avô, ... Junta nomes repetidos em sequência (Helper dentro do mesmo app).
    static func chain(_ ancestors: [ProcSample]) -> [Link] {
        var links: [Link] = []
        for a in ancestors {
            let n = a.appName ?? a.name
            if links.last?.name != n { links.append(Link(pid: a.pid, name: n)) }
        }
        return links
    }

    private static func isUserLaunched(_ p: ProcSample) -> Bool {
        !p.path.contains(".app/") && !systemPrefixes.contains(where: { p.path.hasPrefix($0) })
    }

    /// Texto só para os casos que a cadeia de pais não explica.
    static func hint(for p: ProcSample, ancestors: [ProcSample] = [], args: String) -> String {
        if args.contains("puppeteer_dev_chrome_profile") || args.contains("chrome-devtools-mcp") {
            return "Chrome de automação (chrome-devtools-mcp)"
        }
        if p.ppid == 1, isUserLaunched(p) { return "sem processo pai, iniciado de terminal ou script" }
        if let top = ancestors.last, top.ppid == 1, isUserLaunched(top) { return "quem iniciou já fechou" }
        return ""
    }
}
