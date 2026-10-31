import Foundation
import Security

/// Uso do Claude (janelas de 5 h e 7 dias). Duas fontes: a API (UsageFetcher) e o arquivo que o statusline do
/// Claude Code grava (~/.claude/iland-usage.json). Sem dado = nil (orelhas mostram "—").
struct ClaudeUsage: Decodable {
    struct Window: Decodable { var usedPercentage: Double?; var resetsAt: Double? }
    var updatedAt: Double
    var fiveHour: Window?
    var sevenDay: Window?

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/iland-usage.json")

    static func load() -> ClaudeUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(ClaudeUsage.self, from: data)
    }

    /// Percentual inteiro da janela; se ela já reiniciou desde a última leitura, 0. Sem dado, nil.
    static func percent(_ w: Window?, now: Date = Date()) -> Int? {
        if let r = w?.resetsAt, r <= now.timeIntervalSince1970 { return 0 }
        return w?.usedPercentage.map { Int($0.rounded()) }
    }

    /// Uso do Codex pelo último `rate_limits` gravado nas sessões (o Codex só grava quando é usado). Lê no máximo 1x/min.
    private static var codexCache: (at: Date, value: ClaudeUsage?)?
    static func codex(now: Date = Date()) -> ClaudeUsage? {
        if let c = codexCache, now.timeIntervalSince(c.at) < 60 { return c.value }
        let w = { (o: [String: Any]?) in o.map { Window(usedPercentage: ($0["used_percent"] as? NSNumber)?.doubleValue, resetsAt: ($0["resets_at"] as? NSNumber)?.doubleValue) } }
        let v = CodexSessions.rateLimits().map { ClaudeUsage(updatedAt: $0.at.timeIntervalSince1970, fiveHour: w($0.primary), sevenDay: w($0.secondary)) }
        codexCache = (now, v)
        return v
    }

    /// Dado com mais de 15 min.
    func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince1970 - updatedAt > 15 * 60 }

    /// API recente > arquivo do statusline > o mais novo dos dois (apagado se defasado) > nil.
    static func pick(api: ClaudeUsage?, file: ClaudeUsage?, now: Date = Date()) -> ClaudeUsage? {
        if let a = api, !a.isStale(now: now) { return a }
        return [file, api].compactMap { $0 }.max { $0.updatedAt < $1.updatedAt }
    }
}

/// Consulta GET api.anthropic.com/api/oauth/usage (endpoint não documentado) com o token OAuth do login do
/// Claude Code no Keychain. Nunca renova o token (rotacionaria o refresh token e poderia deslogar o Claude Code):
/// ausente/expirado = sem dado da API, e o app cai no arquivo do statusline. O token só vive em variável local.
final class UsageFetcher {
    private let lock = NSLock()
    private var last: ClaudeUsage?
    private var nextTry = Date.distantPast
    private var inFlight = false
    private var cachedToken: (value: String, expiresAt: Date)?   // só na fila `queue`: 1 leitura do Keychain por token, não por consulta
    /// ILAND_NO_KEYCHAIN=1: nunca toca no Keychain (desenvolvimento: cada build novo seria um app novo para o macOS e pediria senha).
    static let keychainDisabled = ProcessInfo.processInfo.environment["ILAND_NO_KEYCHAIN"] != nil
    private let queue = DispatchQueue(label: "iland.usage", qos: .utility)

    /// Último resultado da API (pode estar defasado; quem decide é ClaudeUsage.pick).
    var latest: ClaudeUsage? { lock.lock(); defer { lock.unlock() }; return last }

    /// Não bloqueia: se já passou o intervalo, dispara uma consulta em fundo.
    func poll(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight, now >= nextTry else { return }
        inFlight = true
        queue.async { self.fetch() }
    }

    private func finish(_ result: ClaudeUsage?, retryIn: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let result { last = result }
        nextTry = Date().addingTimeInterval(retryIn)
        inFlight = false
    }

    private func fetch() {
        if Self.keychainDisabled || !Prefs.bool(Prefs.Key.usageFromAPI) { return finish(nil, retryIn: 300) }
        let token: String
        if let c = cachedToken, c.expiresAt > Date().addingTimeInterval(60) {
            token = c.value
        } else {
            cachedToken = nil
            var status = errSecSuccess
            guard let cred = Self.readCredential(status: &status) else {
                // Negado/cancelado: não pergunta de novo por 1 dia (o statusline continua como fonte). Sem item/expirado: 10-30 min.
                let denied = status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed
                NSLog("iLand usage: token \(status == errSecSuccess ? "expirado/inválido" : denied ? "acesso negado" : "ausente") (\(status))")
                return finish(nil, retryIn: denied ? 86_400 : (status == errSecSuccess ? 600 : 1800))
            }
            cachedToken = cred
            token = cred.value
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.287", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, let data, let u = Self.parse(data) { return self.finish(u, retryIn: 120) }
            NSLog("iLand usage: HTTP \(code)\(code == 200 ? " (formato inesperado)" : "")")
            if code == 401 || code == 403 { self.queue.async { self.cachedToken = nil } }
            self.finish(nil, retryIn: code == 401 || code == 403 ? 1800 : 600)
        }.resume()
    }

    /// Lê pelo `/usr/bin/security`, não pela API do Keychain. O Claude Code grava o item com esse comando e REESCREVE
    /// o item a cada renovação do login: o "Permitir sempre" dado ao iLand sumia e o macOS pedia a senha de novo.
    /// O item confia no `security`, então a leitura por ele não pede nada. A saída só vive nesta função.
    private static func readCredential(status: inout OSStatus) -> (value: String, expiresAt: Date)? {
        let r = CLI.run(URL(fileURLWithPath: "/usr/bin/security"), ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 10)
        // 36/51 = negado ou cancelado no pedido do macOS; 15 = o timeout matou o comando (pedido sem resposta).
        status = switch r.status { case 0: errSecSuccess; case 36, 51: errSecUserCanceled; case 15: errSecInteractionNotAllowed; default: errSecItemNotFound }
        guard r.status == 0 else { return nil }
        let raw = r.out.last == 0x0A ? r.out.dropLast() : r.out
        return credential(fromCredential: Data(raw))
    }

    /// Token e validade do JSON da credencial, só se ainda válido (expiresAt em epoch ms).
    static func credential(fromCredential data: Data, now: Date = Date()) -> (value: String, expiresAt: Date)? {
        struct Cred: Decodable { struct O: Decodable { var accessToken: String; var expiresAt: Double }; var claudeAiOauth: O }
        guard let o = try? JSONDecoder().decode(Cred.self, from: data).claudeAiOauth,
              !o.accessToken.isEmpty, o.expiresAt > now.timeIntervalSince1970 * 1000 else { return nil }
        return (o.accessToken, Date(timeIntervalSince1970: o.expiresAt / 1000))
    }

    static func token(fromCredential data: Data, now: Date = Date()) -> String? { credential(fromCredential: data, now: now)?.value }

    /// Resposta: {"five_hour": {"utilization": 16.0, "resets_at": "2026-10-03T00:59:59.679299+00:00"}, "seven_day": {...}}.
    /// Sem nenhuma das duas utilizations = formato mudou = nil.
    static func parse(_ data: Data, now: Date = Date()) -> ClaudeUsage? {
        struct W: Decodable { var utilization: Double?; var resets_at: String? }
        struct R: Decodable { var five_hour: W?; var seven_day: W? }
        guard let r = try? JSONDecoder().decode(R.self, from: data),
              r.five_hour?.utilization != nil || r.seven_day?.utilization != nil else { return nil }
        func win(_ w: W?) -> ClaudeUsage.Window? {
            w.map { .init(usedPercentage: $0.utilization, resetsAt: $0.resets_at.flatMap(epoch)) }
        }
        return ClaudeUsage(updatedAt: now.timeIntervalSince1970, fiveHour: win(r.five_hour), sevenDay: win(r.seven_day))
    }

    /// ISO 8601; a fração de segundo (vem com 6 dígitos) é descartada antes de converter.
    static func epoch(_ s: String) -> Double? {
        let noFraction = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: noFraction)?.timeIntervalSince1970
    }
}
