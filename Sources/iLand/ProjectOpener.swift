import Foundation

/// `open_project` do assistente: abre a pasta de um projeto no editor da pessoa. Executa direto (ação local e reversível), mas só
/// para um filho DIRETO das raízes de projeto, com .git, sem ponto no começo e sem link para fora (realpath conferido):
/// o Cursor não pede confiança na pasta e um .vscode/tasks.json "runOn: folderOpen" rodaria código. 1 por pergunta.
/// Teste em Tests/Unit/test_opener.swift (opener falso).
struct ProjectOpener {
    static var defaultRoots: [String] { ProjectRoots.openRoots() }
    let opener: (URL) -> Void
    private var lastAsk: String?

    /// `roots` nil = as raízes do momento (a lista cresce conforme a pessoa abre projetos).
    let fixedRoots: [String]?
    var roots: [String] { fixedRoots ?? Self.defaultRoots }
    init(roots: [String]? = nil, opener: @escaping (URL) -> Void) { self.fixedRoots = roots; self.opener = opener }

    /// `requireGit` false = só para ligar uma task a um projeto (nada é aberto): aceita pasta-mãe de vários repositórios.
    static func validate(_ name: String, roots: [String], requireGit: Bool = true) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), name.count <= 80 else { return nil }
        for r in roots {
            let rootReal = URL(fileURLWithPath: r).resolvingSymlinksInPath()
            let candidate = rootReal.appendingPathComponent(name)
            let real = candidate.resolvingSymlinksInPath()
            guard real.deletingLastPathComponent().path == rootReal.path, real.lastPathComponent == name,
                  FileManager.default.fileExists(atPath: real.appendingPathComponent(requireGit ? ".git" : "").path) else { continue }
            return real
        }
        return nil
    }

    mutating func open(_ name: String, ask: String) -> String {
        guard lastAsk != ask else { return "Já abri um projeto nesta pergunta (máximo 1 por pergunta)." }
        guard let url = Self.validate(name, roots: roots) else { return "Não posso abrir \"\(name.prefix(40))\": só pastas de projeto com git que o iLand já conhece." }
        lastAsk = ask
        opener(url)
        return "Abri \(url.lastPathComponent) no \(Editor.name)."
    }
}
