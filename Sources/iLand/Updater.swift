import AppKit
import Security

/// Atualização pelo GitHub Releases, só quando a pessoa clica em "Atualizar".
/// Por que dentro do app: um .dmg baixado pelo navegador ganha quarentena e o macOS bloqueia o app sem notarização
/// a cada versão. O download do URLSession não ganha quarentena, então só a primeira instalação pede a liberação.
/// Antes de trocar, confere que o app novo tem o MESMO requisito de assinatura do atual (mesmo id e mesmo
/// certificado): assim um .dmg trocado no caminho não entra, e as permissões do macOS continuam valendo.
/// Repositório em Info.plist (`ILandRepo`, "dono/nome"). Repositório privado: usa o login do `gh` da pessoa, se houver.
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release { let version: String; let assetURL: URL; let notes: String }

    @Published private(set) var available: Release?
    @Published private(set) var state = ""
    @Published private(set) var busy = false

    static var repo: String? {
        let r = Bundle.main.object(forInfoDictionaryKey: "ILandRepo") as? String ?? ""
        return r.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil ? r : nil
    }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "1.10.0" > "1.9.2". Partes que faltam valem 0; texto depois de "-" é ignorado.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [] }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Uma vez por dia (e no botão de Ajustes). Achou versão nova: avisa uma vez por versão.
    func startDaily() {
        check(silent: true)
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in self?.check(silent: true) }
    }

    func check(silent: Bool = false) {
        guard let repo = Self.repo else { state = silent ? "" : "Repositório de atualização não configurado nesta versão."; return }
        guard !busy else { return }
        busy = true; if !silent { state = "Procurando…" }
        Task.detached {
            let result = await Self.latest(repo: repo)
            await MainActor.run {
                let u = Updater.shared   // singleton: sem capturar self na tarefa concorrente
                u.busy = false
                switch result {
                case .success(let r) where Self.isNewer(r.version, than: Self.current):
                    u.available = r
                    u.state = "Versão \(r.version) disponível."
                    // "Atualização automática" ligada: instala já, menos com um serviço ligado (reabrir o app derrubaria ele).
                    // Nesse caso avisa como sempre e tenta de novo na checagem do dia seguinte.
                    if silent, Prefs.bool(Prefs.Key.autoUpdate), MainWindow.shared.tools?.tunnels.anyOn != true { return u.install() }
                    if UserDefaults.standard.string(forKey: "updateNotified") != r.version {
                        UserDefaults.standard.set(r.version, forKey: "updateNotified")
                        Notifier.send(title: "iLand \(r.version) disponível", message: "Abra o menu do iLand e clique em Atualizar.", id: "update")
                    }
                case .success: u.available = nil; u.state = silent ? "" : "Você já está na versão mais nova (\(Self.current))."
                case .failure(let e): u.state = silent ? "" : e.message
                }
            }
        }
    }

    struct Failure: Error { let message: String }

    private static func latest(repo: String) async -> Result<Release, Failure> {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (d, r) = try? await authorized(req, { try await URLSession.shared.data(for: $0) }) else { return .failure(Failure(message: "Sem conexão com o GitHub.")) }
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return .failure(Failure(message: "Não achei a versão no GitHub. Se o repositório é privado, faça `gh auth login` no terminal.")) }
        guard code == 200, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let tag = o["tag_name"] as? String,
              let asset = (o["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let api = (asset["url"] as? String).flatMap(URL.init(string:)) else { return .failure(Failure(message: "Resposta do GitHub inesperada (\(code)).")) }
        return .success(Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")), assetURL: api, notes: o["body"] as? String ?? ""))
    }

    /// Com o token do `gh`, se houver. Token vencido dá 401 até em repositório público: aí tenta de novo sem ele.
    private static func authorized<T>(_ req: URLRequest, _ send: (URLRequest) async throws -> (T, URLResponse)) async throws -> (T, URLResponse) {
        guard let t = ghToken() else { return try await send(req) }
        var withAuth = req
        withAuth.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        let r = try await send(withAuth)
        return (r.1 as? HTTPURLResponse)?.statusCode == 401 ? try await send(req) : r
    }

    /// Token do `gh` (só para repositório privado). Nunca é salvo nem logado.
    private static func ghToken() -> String? {
        guard let gh = CLI.locate("gh") else { return nil }
        let r = CLI.run(gh, ["auth", "token"], timeout: 10)
        let t = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !t.isEmpty ? t : nil
    }

    // MARK: instalar

    func install() {
        guard let rel = available, !busy else { return }
        busy = true; state = "Baixando \(rel.version)…"
        Task.detached {
            let msg: String
            do { try await Self.download(rel); msg = "" } catch let e as Failure { msg = e.message } catch { msg = error.localizedDescription }
            await MainActor.run { Updater.shared.busy = false; if !msg.isEmpty { Updater.shared.state = msg } }
        }
    }

    private static func download(_ rel: Release) async throws {
        var req = URLRequest(url: rel.assetURL, timeoutInterval: 300)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (tmp, resp) = try await authorized(req, { try await URLSession.shared.download(for: $0) })
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "Download falhou.") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("iland-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dmg = work.appendingPathComponent("iLand.dmg"), mount = work.appendingPathComponent("mnt"), staged = work.appendingPathComponent("iLand.app")
        try fm.moveItem(at: tmp, to: dmg)
        let hdi = URL(fileURLWithPath: "/usr/bin/hdiutil")
        guard CLI.run(hdi, ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path], timeout: 60).status == 0 else {
            throw Failure(message: "Não consegui abrir o .dmg.")
        }
        defer { _ = CLI.run(hdi, ["detach", "-force", mount.path], timeout: 30) }
        try fm.copyItem(at: mount.appendingPathComponent("iLand.app"), to: staged)
        _ = CLI.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", staged.path], timeout: 30)
        guard sameSigner(staged) else { throw Failure(message: "A versão baixada não tem a assinatura do iLand. Não instalei.") }
        try await MainActor.run { try replaceAndRelaunch(with: staged) }
    }

    /// O app novo satisfaz o requisito de assinatura do app que está rodando (mesmo id e mesmo certificado).
    static func sameSigner(_ app: URL) -> Bool {
        var me: SecCode?, req: SecRequirement?, other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), req) == errSecSuccess
    }

    @MainActor private static func replaceAndRelaunch(with staged: URL) throws {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        let old = fm.temporaryDirectory.appendingPathComponent("iLand-old-\(UUID().uuidString).app")
        try fm.moveItem(at: target, to: old)
        do { try fm.moveItem(at: staged, to: target) } catch { try? fm.moveItem(at: old, to: target); throw Failure(message: "Não consegui trocar o app: \(error.localizedDescription)") }
        // Reabre depois que este processo sair de fato e apaga o app antigo. Caminhos e pid vão como argumentos.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$2\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"; /bin/rm -rf \"$1\"",
                       target.path, old.path, String(getpid())]
        try? p.run()
        NSApp.terminate(nil)
    }
}
