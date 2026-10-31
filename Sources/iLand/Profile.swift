import AppKit

/// Editor e terminal escolhidos pela pessoa (Ajustes › Perfil). Sem escolha, o primeiro instalado da lista.
enum Editor {
    static let known: [(bundle: String, name: String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"), ("com.microsoft.VSCode", "VS Code"), ("dev.zed.Zed", "Zed"),
        ("com.exafunction.windsurf", "Windsurf"), ("com.jetbrains.intellij", "IntelliJ IDEA"), ("com.jetbrains.pycharm", "PyCharm"),
        ("com.jetbrains.WebStorm", "WebStorm"), ("com.apple.dt.Xcode", "Xcode"), ("com.sublimetext.4", "Sublime Text"),
    ]
    static var installed: [(bundle: String, name: String)] { known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil } }

    static var bundle: String? {
        let b = Prefs.string(Prefs.Key.editor)
        if !b.isEmpty, NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil { return b }
        return installed.first?.bundle
    }
    static var name: String { known.first { $0.bundle == bundle }?.name ?? "Finder" }

    /// Todos os editores conhecidos: o registro de atividade lê o projeto pelo título de qualquer um deles.
    static var bundles: Set<String> { Set(known.map(\.bundle)) }

    /// Abre a pasta no editor da pessoa; sem editor instalado, no Finder.
    static func open(_ url: URL) {
        if let b = bundle, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(url) }
    }
}

enum Terminal {
    static let known: [(bundle: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm2"), ("dev.warp.Warp-Stable", "Warp"),
        ("com.mitchellh.ghostty", "Ghostty"),
    ]
    static var installed: [(bundle: String, name: String)] { known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil } }
    static var bundles: Set<String> { Set(known.map(\.bundle)) }
    static var bundle: String {
        let b = Prefs.string(Prefs.Key.terminal)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil ? b : "com.apple.Terminal"
    }

    /// Abre o terminal da pessoa rodando `ssh <host>`. O host já passou por Prefs.isValidHost (sem espaço nem aspas).
    /// Terminal e iTerm2 por AppleScript (texto fixo + host validado); os outros abrem um arquivo .command.
    static func ssh(_ host: String) {
        guard Prefs.isValidHost(host) else { return }
        let script: String? = switch bundle {
        case "com.apple.Terminal": "tell application \"Terminal\"\n do script \"ssh \(host)\"\n activate\nend tell"
        case "com.googlecode.iterm2": "tell application \"iTerm\"\n create window with default profile command \"ssh \(host)\"\n activate\nend tell"
        default: nil
        }
        if let script {
            DispatchQueue.global().async {
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
                if let err { NSLog("iLand: abrir ssh falhou: \(err)") }
            }
            return
        }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("iland-ssh-\(host).command")
        try? Data("#!/bin/sh\nexec ssh \(host)\n".utf8).write(to: f)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.open([f], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Onde ficam os projetos de cada pessoa, sem pasta fixa. Um projeto é uma pasta com `.git`. O app aprende os projetos
/// pelo que a pessoa abre (documento do editor, sessões do Claude Code e do Codex) e guarda a lista em UserDefaults.
/// A pasta-mãe de um projeto aprendido vira raiz de busca, para achar os irmãos (exceto a home: varrer a home é caro).
/// Pastas adicionadas à mão em Ajustes também são raízes, e as subpastas de 1º nível delas contam como projeto
/// mesmo sem `.git`.
enum ProjectRoots {
    static let key = "learnedProjects"
    static let limit = 300

    static var learned: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    /// Guarda o repositório de `path` (o ancestral com .git mais fundo). Fora da home ou em pasta oculta: ignora.
    static func learn(_ path: String) {
        let home = NSHomeDirectory()
        guard let repo = ProjectResolver.root(forPath: path, exists: { FileManager.default.fileExists(atPath: $0 + "/.git") }),
              repo.hasPrefix(home + "/"), !repo.dropFirst(home.count + 1).hasPrefix("."), !repo.contains("/node_modules/") else { return }
        var l = learned
        guard !l.contains(repo) else { return }
        l.append(repo)
        UserDefaults.standard.set(Array(l.suffix(limit)), forKey: key)
    }

    /// Esquece projetos que não existem mais.
    static var known: [String] { learned.filter { FileManager.default.fileExists(atPath: $0 + "/.git") } }

    static var manual: [String] { Prefs.projectRoots.map(\.path) }

    /// Raízes que a busca varre (até 3 níveis): as manuais e as pastas-mãe dos aprendidos. Fora: a home (cara) e as
    /// pastas protegidas do macOS (varrer abriria pedidos de permissão sem contexto).
    static func scanRoots() -> [String] {
        let home = NSHomeDirectory()
        let protected = ["Documents", "Desktop", "Downloads", "Library", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
        var out = manual
        for p in known {
            let parent = (p as NSString).deletingLastPathComponent
            guard parent != home, parent != "/", !protected.contains(where: { parent == $0 || parent.hasPrefix($0 + "/") }), !out.contains(parent) else { continue }
            out.append(parent)
        }
        return out
    }

    /// Raízes onde `open_project` aceita um filho direto: as de busca e as pastas-mãe dos aprendidos (a home inclusive).
    static func openRoots() -> [String] {
        var out = scanRoots()
        for p in known { let parent = (p as NSString).deletingLastPathComponent; if !out.contains(parent) { out.append(parent) } }
        return out
    }

    /// Projetos conhecidos: pastas com .git nas raízes (até 3 níveis; sem node_modules nem ocultas), os aprendidos e
    /// as pastas de 1º nível das raízes manuais.
    static func scan() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            if fm.fileExists(atPath: dir + "/.git") { out.append(dir) }
            guard depth < 3, let kids = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for k in kids where !k.hasPrefix(".") && k != "node_modules" {
                var isDir: ObjCBool = false
                let p = dir + "/" + k
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { walk(p, depth + 1) }
            }
        }
        for r in scanRoots() { walk(r, 0) }
        for p in known where !out.contains(p) { out.append(p) }
        let tops = manual.flatMap { r in ((try? fm.contentsOfDirectory(atPath: r)) ?? []).filter { !$0.hasPrefix(".") }.map { r + "/" + $0 } }
        for t in tops where !out.contains(t) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: t, isDirectory: &isDir), isDir.boolValue { out.append(t) }
        }
        return out
    }

    /// Primeiro uso: aprende pelas pastas das sessões do Claude Code e do Codex dos últimos 30 dias.
    static func bootstrap() {
        for cwd in ClaudeSessions.cwds(days: 30) + CodexSessions.cwds(days: 30) { learn(cwd) }
    }
}
