import Foundation

/// Provedores de modelo que a pessoa conecta (Ajustes › Modelos). Cada papel do app usa um provedor e um modelo.
/// Nada de chave de API guardada pelo iLand: Claude Code e Codex usam o login dos próprios CLIs; Ollama roda local
/// (modelos cloud passam pelo `ollama signin` da pessoa).
enum Provider: String, CaseIterable, Identifiable {
    case claude, codex, ollama
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .ollama: "Ollama"
        }
    }
    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .ollama: "cube.fill"
        }
    }
    /// Modelos sugeridos (a pessoa pode digitar outro). Ollama: a lista vem do `ollama list`.
    var suggested: [String] {
        switch self {
        case .claude: ["haiku", "sonnet", "opus"]
        case .codex: ["gpt-5-codex", "gpt-5"]
        case .ollama: []
        }
    }
}

/// Tarefas do app que usam modelo. Só o assistente precisa de ferramentas.
enum Role: String, CaseIterable, Identifiable {
    case assistant, summary, explain, quick
    var id: String { rawValue }
    var key: String {
        switch self {
        case .assistant: Prefs.Key.roleAssistant
        case .summary: Prefs.Key.roleSummary
        case .explain: Prefs.Key.roleExplain
        case .quick: Prefs.Key.roleQuick
        }
    }
    var title: String {
        switch self {
        case .assistant: "Assistente (conversa e ferramentas)"
        case .summary: "Resumo do dia"
        case .explain: "Explicar máquina"
        case .quick: "Pergunta rápida (sem assistente)"
        }
    }

    /// "provedor:modelo". O modelo do Ollama pode ter ":" (gpt-oss:120b-cloud), por isso só o 1º ":" separa.
    var choice: (provider: Provider, model: String) {
        let raw = Prefs.string(key)
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let p = Provider(rawValue: parts.first ?? "") ?? .claude
        let m = parts.count > 1 ? parts[1] : (p.suggested.first ?? "")
        return (p, LLM.safeModel(m) ? m : (p.suggested.first ?? ""))
    }
    func set(_ p: Provider, _ model: String) { UserDefaults.standard.set("\(p.rawValue):\(model)", forKey: key) }
}

/// Acha um executável: nos lugares comuns e, se não achar, no PATH do shell de login da pessoa (nvm, volta, asdf).
/// O resultado fica guardado até o app fechar.
enum CLI {
    private static var cache: [String: URL?] = [:]
    private static let lock = NSLock()

    static func locate(_ name: String) -> URL? {
        lock.lock(); if let c = cache[name] { lock.unlock(); return c }; lock.unlock()
        let home = NSHomeDirectory()
        let fixed = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.claude/local/\(name)",
                     "\(home)/.npm-global/bin/\(name)", "\(home)/.volta/bin/\(name)", "\(home)/.bun/bin/\(name)"]
        var found = fixed.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if found == nil { found = loginShellPath(name) }
        if found != nil { lock.lock(); cache[name] = found; lock.unlock() }   // "não achei" não fica guardado: a pessoa pode instalar depois
        return found
    }

    /// Esquece o que já achou ("Verificar de novo" em Ajustes).
    static func reset() { lock.lock(); cache = [:]; lock.unlock() }

    /// Na abertura, fora da main: o 1º `locate` pode rodar o shell de login, que é lento.
    static func warmUp() { DispatchQueue.global(qos: .utility).async { for n in ["claude", "codex", "ollama", "gh"] { _ = locate(n) } } }

    /// `zsh -lic 'command -v <nome>'` (-i lê o ~/.zshrc, onde o nvm costuma ficar). O nome é fixo no código, nunca texto
    /// de fora. Vale a última linha que é um caminho (o rc pode imprimir outras coisas). Espera no máximo 6 s, mesmo
    /// se um processo filho do rc segurar o pipe aberto.
    private static func loginShellPath(_ name: String) -> URL? {
        guard ["claude", "codex", "ollama", "gh"].contains(name) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + 6) == .timedOut { p.terminate(); return nil }
        let path = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") } ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// PATH para os CLIs filhos: o app de interface não herda o PATH do terminal (o `claude` instalado pelo npm chama `node`).
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dirs = ["claude", "codex"].compactMap { locate($0)?.deletingLastPathComponent().path }
        env["PATH"] = (dirs + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":") + ":" + (env["PATH"] ?? "")
        return env
    }

    /// Roda um processo, junta stdout e stderr sem travar (cada pipe na sua fila) e corta em `timeout` segundos.
    static func run(_ exe: URL, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil, timeout: TimeInterval = 120,
                    onStart: (Process) -> Void = { _ in }) -> (status: Int32, out: Data, err: Data) {
        let task = Process()
        task.executableURL = exe
        task.arguments = args
        task.currentDirectoryURL = cwd ?? FileManager.default.temporaryDirectory
        task.environment = env ?? environment
        let out = Pipe(), err = Pipe()
        task.standardOutput = out; task.standardError = err; task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, Data(), Data(error.localizedDescription.utf8)) }
        onStart(task)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if task.isRunning { task.terminate() } }
        var errData = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        task.waitUntilExit()
        return (task.terminationStatus, data, errData)
    }
}

/// Pergunta simples (sem ferramentas) ao provedor do papel. A resposta volta na fila principal.
enum LLM {
    static let maxReply = 6000

    /// O modelo vai como argumento ou no JSON: só letras, números e . : _ - /.
    static func safeModel(_ m: String) -> Bool { m.range(of: "^[A-Za-z0-9][A-Za-z0-9.:_/-]{0,79}$", options: .regularExpression) != nil }

    static let style = "Responda em português do Brasil, curto e direto (cabe num painel pequeno). Texto simples, sem markdown."

    /// Devolve o processo (para cancelar) quando há um; o Ollama é uma chamada HTTP e não devolve nada.
    @discardableResult
    static func ask(_ prompt: String, role: Role, completion: @escaping (String) -> Void) -> Process? {
        let (p, model) = role.choice
        let finish: (String) -> Void = { t in DispatchQueue.main.async { completion(String(t.prefix(maxReply))) } }
        switch p {
        case .claude: return ClaudeCLI.ask(prompt, model: model, completion: completion)
        case .codex: return CodexCLI.ask(prompt, model: model, completion: completion)
        case .ollama:
            Task.detached {
                do {
                    let m = try await Ollama.chat(model: model, messages: [["role": "system", "content": style], ["role": "user", "content": prompt]], tools: nil)
                    finish(m.content.isEmpty ? "(sem resposta)" : m.content)
                } catch { finish("O Ollama não respondeu: \(error.localizedDescription)") }
            }
            return nil
        }
    }
}

/// API local do Ollama (http://127.0.0.1:11434). Modelos cloud (`…-cloud`) passam pelo Ollama local com o login da pessoa.
enum Ollama {
    static let base = URL(string: "http://127.0.0.1:11434")!

    struct Reply { var content: String; var toolCalls: [(name: String, args: [String: Any])]; var raw: [String: Any] }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Modelos instalados (`/api/tags`). nil = Ollama fechado ou não instalado.
    static func models() async -> [String]? {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let list = o["models"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["name"] as? String }.sorted()
    }

    /// Uma volta de `/api/chat` sem streaming. `tools` no formato do Ollama (type function + parameters JSON Schema).
    static func chat(model: String, messages: [[String: Any]], tools: [[String: Any]]?) async throws -> Reply {
        guard LLM.safeModel(model) else { throw Failure(message: "modelo inválido") }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        if let tools { body["tools"] = tools }
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, r) = try await URLSession.shared.data(for: req)
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard (r as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: (o["error"] as? String).map { String($0.prefix(200)) } ?? "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let msg = o["message"] as? [String: Any] ?? [:]
        let calls = (msg["tool_calls"] as? [[String: Any]] ?? []).compactMap { c -> (String, [String: Any])? in
            guard let f = c["function"] as? [String: Any], let n = f["name"] as? String else { return nil }
            let args = f["arguments"] as? [String: Any]
                ?? (f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            return (n, args)
        }
        return Reply(content: (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls, raw: o)
    }
}
