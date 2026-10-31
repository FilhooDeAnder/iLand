import Foundation
import CryptoKit
import Security

struct S3Config: Codable, Equatable {
    var bucket = ""
    var region = "us-east-1"
    var prefix = "prints/"
    var expiresHours = 24          // validade do link (1...168)
    var enabled = true             // false = envio desligado
    var endpoint = ""              // vazio = Amazon; senão R2, MinIO, Backblaze… ("https://host[:porta]")
    var sharing = "presigned"      // none | presigned | public
    var publicBase = ""            // início do link público ("https://cdn.exemplo.com/")
    /// Bucket e região só com caracteres válidos da AWS: impede URL inválida e envio do PUT assinado para outro servidor.
    static func validBucket(_ s: String) -> Bool { s.range(of: #"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil }
    static func validRegion(_ s: String) -> Bool { s.range(of: #"^[a-z]{2}(-[a-z]+)+-[0-9]{1,2}$"#, options: .regularExpression) != nil }
    /// R2 usa "auto"; o resto dos serviços compatíveis aceita nome simples.
    static func validCustomRegion(_ s: String) -> Bool { s.range(of: #"^[a-z0-9][a-z0-9-]{0,30}$"#, options: .regularExpression) != nil }
    /// Só https (http só em localhost, para testar MinIO), sem usuário, caminho, query nem fragmento.
    static func validEndpoint(_ s: String) -> Bool {
        guard !s.isEmpty else { return true }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty, u.user == nil, u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/" else { return false }
        return u.scheme == "https" || (u.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
    }
    var custom: Bool { !endpoint.isEmpty }
    var isComplete: Bool {
        Self.validBucket(bucket) && Self.validEndpoint(endpoint) && (custom ? Self.validCustomRegion(region) : Self.validRegion(region))
            && (sharing != "public" || publicBase.isEmpty || URL(string: publicBase)?.scheme?.hasPrefix("http") == true)
    }
}

extension S3Config {
    /// Lê configurações antigas (sem os campos novos) sem perder o que já estava salvo.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? bucket
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? region
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? prefix
        expiresHours = try c.decodeIfPresent(Int.self, forKey: .expiresHours) ?? expiresHours
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        sharing = try c.decodeIfPresent(String.self, forKey: .sharing) ?? sharing
        publicBase = try c.decodeIfPresent(String.self, forKey: .publicBase) ?? publicBase
    }
}

struct S3Credentials: Codable, Equatable {
    var accessKey: String
    var secret: String
}

/// AWS Signature V4 (lógica pura, validada com os vetores de teste da própria AWS).
enum SigV4 {
    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hmac(_ key: Data, _ message: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))) }

    static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        hmac(hmac(hmac(hmac(Data("AWS4\(secret)".utf8), date), region), service), "aws4_request")
    }

    /// Codificação de URI da AWS: só A-Z a-z 0-9 - _ . ~ ficam; "/" fica nos caminhos.
    static func encode(_ s: String, keepSlash: Bool = false) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E: out.append(Character(UnicodeScalar(b)))
            case 0x2F where keepSlash: out.append("/")
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static func amzDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    private static func sign(canonical: String, amzDate: String, region: String, service: String, secret: String) -> (signature: String, scope: String) {
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(sha256Hex(Data(canonical.utf8)))"
        let key = signingKey(secret: secret, date: day, region: region, service: service)
        return (hmac(key, toSign).map { String(format: "%02x", $0) }.joined(), scope)
    }

    /// Cabeçalho Authorization para uma requisição assinada. `headers`: nomes em minúsculas, já com host e x-amz-date.
    static func authorization(method: String, path: String, query: [(String, String)] = [], headers: [String: String], payloadHash: String,
                              creds: S3Credentials, region: String, service: String, amzDate: String) -> String {
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signed = names.joined(separator: ";")
        let q = canonicalQuery(query)
        let canonical = "\(method)\n\(encode(path, keepSlash: true))\n\(q)\n\(canonicalHeaders)\n\(signed)\n\(payloadHash)"
        let s = sign(canonical: canonical, amzDate: amzDate, region: region, service: service, secret: creds.secret)
        return "AWS4-HMAC-SHA256 Credential=\(creds.accessKey)/\(s.scope), SignedHeaders=\(signed), Signature=\(s.signature)"
    }

    /// Query canônica: nomes e valores codificados, ordenados por nome e depois por valor.
    static func canonicalQuery(_ items: [(String, String)]) -> String {
        var pairs: [(String, String)] = []
        for item in items { pairs.append((encode(item.0), encode(item.1))) }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return pairs.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
    }

    /// Link assinado (GET) que expira: devolve a query string completa, com X-Amz-Signature.
    static func presignQuery(host: String, path: String, creds: S3Credentials, region: String, expires: Int, amzDate: String) -> String {
        let day = String(amzDate.prefix(8))
        let params: [(String, String)] = [("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
                                          ("X-Amz-Credential", "\(creds.accessKey)/\(day)/\(region)/s3/aws4_request"),
                                          ("X-Amz-Date", amzDate), ("X-Amz-Expires", String(expires)), ("X-Amz-SignedHeaders", "host")]
        let q = canonicalQuery(params)
        let canonical = "GET\n\(encode(path, keepSlash: true))\n\(q)\nhost:\(host)\n\nhost\nUNSIGNED-PAYLOAD"
        let s = sign(canonical: canonical, amzDate: amzDate, region: region, service: "s3", secret: creds.secret)
        return "\(q)&X-Amz-Signature=\(s.signature)"
    }
}

/// Endereço do objeto: bucket com ponto não serve para HTTPS virtual-hosted, então usa o estilo de caminho.
struct S3Target: Equatable {
    let scheme: String
    let host: String   // com a porta, se não for a padrão
    let path: String   // começa com "/"
    var url: URL { URL(string: "\(scheme)://\(host)\(SigV4.encode(path, keepSlash: true))") ?? URL(string: "https://invalid.invalid/")! }

    init(config: S3Config, key: String) {
        if config.custom, let u = URL(string: config.endpoint), let h = u.host {   // serviço compatível: sempre estilo de caminho
            scheme = u.scheme ?? "https"; host = u.port.map { "\(h):\($0)" } ?? h; path = "/\(config.bucket)/\(key)"
            return
        }
        scheme = "https"
        let regional = config.region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(config.region).amazonaws.com"
        if config.bucket.contains(".") { host = regional; path = "/\(config.bucket)/\(key)" }
        else { host = "\(config.bucket).\(regional)"; path = "/\(key)" }
    }
}

/// Envio em andamento: cancela a tentativa atual e impede as próximas.
final class S3Upload {
    fileprivate var task: URLSessionTask?
    fileprivate(set) var cancelled = false
    func cancel() { cancelled = true; task?.cancel() }
}

enum S3Client {
    static func objectKey(prefix: String, now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        var p = prefix.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("/") { p.removeFirst() }
        if !p.isEmpty, !p.hasSuffix("/") { p += "/" }
        let rand = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(p)print-\(f.string(from: now))-\(rand).png"
    }

    /// Link que vai para a área de transferência, conforme o modo escolhido. "none" devolve o endereço sem assinatura (não é compartilhável).
    static func link(config: S3Config, target: S3Target, creds: S3Credentials, key: String, date: String) -> URL {
        switch config.sharing {
        case "public":
            let base = config.publicBase.trimmingCharacters(in: .whitespaces)
            if !base.isEmpty { return URL(string: (base.hasSuffix("/") ? base : base + "/") + SigV4.encode(key, keepSlash: true)) ?? target.url }
            return target.url
        case "none": return target.url
        default:
            let hours = min(max(config.expiresHours, 1), 168)
            let q = SigV4.presignQuery(host: target.host, path: target.path, creds: creds, region: config.region, expires: hours * 3600, amzDate: date)
            return URL(string: "\(target.url.absoluteString)?\(q)") ?? target.url
        }
    }

    private final class Progress: NSObject, URLSessionTaskDelegate {
        let report: (Double) -> Void
        init(_ report: @escaping (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
        }
    }

    /// PUT assinado e, se deu certo, o link. Tenta de novo (até 2 vezes) em falha de rede ou erro 5xx.
    /// Devolve o envio em andamento para quem quiser cancelar.
    @discardableResult
    static func upload(file: URL, config: S3Config, creds: S3Credentials, now: Date = Date(), progress: @escaping (Double) -> Void = { _ in },
                       completion: @escaping (Result<URL, Error>) -> Void) -> S3Upload? {
        guard config.enabled, config.isComplete, let data = try? Data(contentsOf: file), data.count < 50_000_000 else {
            completion(.failure(S3Error.invalid("arquivo ou configuração inválidos"))); return nil
        }
        let key = objectKey(prefix: config.prefix, now: now)
        let target = S3Target(config: config, key: key)
        let session = URLSession(configuration: .ephemeral, delegate: Progress(progress), delegateQueue: nil)
        let holder = S3Upload()
        func attempt(_ n: Int) {
            let date = SigV4.amzDate(Date()), hash = SigV4.sha256Hex(data)
            let headers = ["host": target.host, "x-amz-content-sha256": hash, "x-amz-date": date, "content-type": "image/png"]
            let auth = SigV4.authorization(method: "PUT", path: target.path, headers: headers, payloadHash: hash, creds: creds, region: config.region, service: "s3", amzDate: date)
            var req = URLRequest(url: target.url, timeoutInterval: 60)
            req.httpMethod = "PUT"
            for (k, v) in headers where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue(auth, forHTTPHeaderField: "Authorization")
            let task = session.uploadTask(with: req, from: data) { body, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let cancelled = (err as? URLError)?.code == .cancelled
                if !cancelled, !holder.cancelled, n < 2, err != nil || code >= 500 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + (n == 0 ? 1 : 3)) { attempt(n + 1) }
                    return
                }
                session.finishTasksAndInvalidate()
                if let err { return completion(.failure(err)) }
                guard code == 200 else { return completion(.failure(S3Error.http(code, S3Error.message(from: body)))) }
                completion(.success(link(config: config, target: target, creds: creds, key: key, date: date)))
            }
            holder.task = task
            if holder.cancelled { task.cancel() } else { task.resume() }
        }
        attempt(0)
        return holder
    }

    /// Testa a conexão: HEAD assinado no bucket. 200 = ok; 403 = chave errada ou sem permissão; 404 = bucket não existe.
    static func testConnection(config: S3Config, creds: S3Credentials, completion: @escaping (Result<Void, Error>) -> Void) {
        guard config.isComplete else { return completion(.failure(S3Error.invalid("preencha bucket, região e endereço"))) }
        let probe = S3Target(config: config, key: "")
        let isPath = config.custom || config.bucket.contains(".")
        let path = isPath ? "/\(config.bucket)/" : "/"
        let date = SigV4.amzDate(Date()), hash = SigV4.sha256Hex(Data())
        let headers = ["host": probe.host, "x-amz-content-sha256": hash, "x-amz-date": date]
        let auth = SigV4.authorization(method: "HEAD", path: path, headers: headers, payloadHash: hash, creds: creds, region: config.region, service: "s3", amzDate: date)
        var req = URLRequest(url: URL(string: "\(probe.scheme)://\(probe.host)\(path)")!, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        for (k, v) in headers where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { return completion(.failure(err)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: completion(.success(()))
            case 403: completion(.failure(S3Error.invalid("acesso negado (chave errada ou sem permissão no bucket)")))
            case 404: completion(.failure(S3Error.invalid("bucket não encontrado")))
            case 301, 400: completion(.failure(S3Error.invalid("região ou endereço errado")))
            default: completion(.failure(S3Error.http(code, "")))
            }
        }.resume()
    }
}

enum S3Error: Error, LocalizedError {
    case invalid(String), http(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalid(let s): s
        case .http(let c, let m): "S3 respondeu \(c)\(m.isEmpty ? "" : ": \(m)")"
        }
    }
    /// Só Code e Message do XML de erro (nunca devolve o corpo todo).
    static func message(from body: Data?) -> String {
        guard let b = body, let s = String(data: b.prefix(4000), encoding: .utf8) else { return "" }
        func tag(_ t: String) -> String? { s.range(of: "<\(t)>").flatMap { r in s.range(of: "</\(t)>").map { String(s[r.upperBound..<$0.lowerBound]) } } }
        return [tag("Code"), tag("Message")].compactMap { $0 }.joined(separator: " - ")
    }
}

/// Credenciais da AWS no Keychain (item próprio do iLand).
enum S3Keychain {
    private static let service = "iLand-S3"
    private static let account = "credentials"

    static func load() -> S3Credentials? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(S3Credentials.self, from: d)
    }

    @discardableResult static func save(_ c: S3Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(c) else { return false }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { return SecItemAdd(base.merging([kSecValueData as String: data]) { a, _ in a } as CFDictionary, nil) == errSecSuccess }
        return status == errSecSuccess
    }

    static func delete() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary) }
}
