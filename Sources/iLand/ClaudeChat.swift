import Foundation

enum ClaudeCLI {
    static func locate() -> URL? { CLI.locate("claude") }

    /// Pergunta única, sem ferramentas e sem sessão salva. O texto vai como UM argumento depois de `--` (sem shell,
    /// e uma pergunta que comece com "-" não vira opção). `--setting-sources ""`: ignora hooks e configs do usuário
    /// (sobe de ~11 s para ~3,5 s e evita efeito colateral de hook).
    static func arguments(prompt: String, model: String) -> [String] {
        ["-p", "--output-format", "text", "--no-session-persistence", "--tools", "", "--model", model, "--setting-sources", "",
         "--append-system-prompt", LLM.style, "--", prompt]
    }

    /// Roda `claude -p` (máx. 2 min) e devolve a resposta (ou a mensagem de erro) na fila principal.
    @discardableResult
    static func ask(_ prompt: String, model: String, completion: @escaping (String) -> Void) -> Process? {
        guard let exe = locate() else { completion("Não achei o `claude` instalado neste Mac. Veja Ajustes › Modelos."); return nil }
        guard LLM.safeModel(model) else { completion("Modelo inválido nos Ajustes."); return nil }
        var env = CLI.environment
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"   // pergunta simples: não carrega os conectores do claude.ai (ClickUp, Gmail…)
        var proc: Process?
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CLI.run(exe, arguments(prompt: prompt, model: model), env: env) { proc = $0; started.signal() }
            if r.status == -1 { started.signal() }
            var text = String(decoding: r.out.prefix(LLM.maxReply * 4), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = r.status == 0 ? "(sem resposta)" : "Não consegui responder (código \(r.status)). " + String(decoding: r.err.prefix(300), as: UTF8.self) }
            let reply = String(text.prefix(LLM.maxReply))
            DispatchQueue.main.async { completion(reply) }
        }
        started.wait()
        return proc
    }
}

/// `codex exec` com o login da pessoa: sem shell, sem escrita (sandbox read-only) e sem a config dela.
enum CodexCLI {
    static func locate() -> URL? { CLI.locate("codex") }

    /// Desliga as ferramentas embutidas que dá para desligar. O `apply_patch` não tem chave: o sandbox read-only bloqueia a escrita.
    static let lockdown = ["-c", "features.shell_tool=false", "-c", "features.unified_exec=false", "-c", "web_search=\"disabled\"",
                           "-c", "tools.view_image=false", "-c", "features.multi_agent=false", "-c", "features.apps=false", "-c", "features.plugins=false"]

    /// `extra` vem antes do prompt (MCP do assistente). O prompt vai depois de `--`, com as instruções na frente
    /// (o exec não tem opção de prompt de sistema que valha em todas as versões).
    static func arguments(prompt: String, model: String, system: String, extra: [String] = [], resume: String? = nil) -> [String] {
        var a = ["exec", "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-s", "read-only", "-m", model] + lockdown + extra
        if let resume { a += ["resume", resume] }
        return a + ["--", "[Instruções do iLand]\n" + system + "\n\n[Pergunta]\n" + prompt]
    }

    /// Texto como string TOML básica (o `-c` lê o valor como TOML).
    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    struct Result { var text = ""; var threadId: String?; var tokens = 0; var tools: [String] = []; var error: String? }

    /// Lê os eventos JSONL do `--json`: o texto final é o último `agent_message`; o id da sessão vem em `thread.started`.
    static func parse(_ data: Data, onTool: (String) -> Void = { _ in }) -> Result {
        var r = Result()
        for line in data.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { continue }
            switch type {
            case "thread.started": r.threadId = o["thread_id"] as? String
            case "item.completed":
                let item = o["item"] as? [String: Any] ?? [:]
                if item["type"] as? String == "agent_message", let t = item["text"] as? String { r.text = t }
                if item["type"] as? String == "mcp_tool_call", let t = item["tool"] as? String { r.tools.append(t); onTool(t) }
            case "turn.completed":
                let u = o["usage"] as? [String: Any] ?? [:]
                r.tokens = (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
            case "turn.failed": r.error = ((o["error"] as? [String: Any])?["message"] as? String) ?? "falhou"
            case "error": r.error = o["message"] as? String ?? "erro"
            default: break
            }
        }
        return r
    }

    @discardableResult
    static func ask(_ prompt: String, model: String, completion: @escaping (String) -> Void) -> Process? {
        guard let exe = locate() else { completion("Não achei o `codex` instalado neste Mac. Veja Ajustes › Modelos."); return nil }
        guard LLM.safeModel(model) else { completion("Modelo inválido nos Ajustes."); return nil }
        var proc: Process?
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let run = CLI.run(exe, ["exec", "--ephemeral"] + arguments(prompt: prompt, model: model, system: LLM.style).dropFirst()) { proc = $0; started.signal() }
            if run.status == -1 { started.signal() }
            let r = parse(run.out)
            let text = !r.text.isEmpty ? r.text : "Não consegui responder: " + (r.error ?? String(decoding: run.err.suffix(300), as: UTF8.self))
            DispatchQueue.main.async { completion(String(text.prefix(LLM.maxReply))) }
        }
        started.wait()
        return proc
    }
}
