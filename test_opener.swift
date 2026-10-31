// Uso: swiftc -parse-as-library Sources/iLand/ProjectOpener.swift Sources/iLand/Profile.swift Sources/iLand/Prefs.swift Sources/iLand/Projects.swift Sources/iLand/SuspectTracker.swift test_opener.swift -o /tmp/t_open && /tmp/t_open
// Pastas temporárias; o "opener" é falso (nada abre o Cursor no teste).
import Foundation

@main struct OpenerCheck {
    static func main() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iland-open-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("Projetos")
        for p in ["api-demo/.git", "semgit", ".oculto/.git", "api-demo/sub/.git"] { try! fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true) }
        try! fm.createSymbolicLink(at: root.appendingPathComponent("atalho"), withDestinationURL: base)   // link para fora da raiz
        let roots = [root.path]

        assert(ProjectOpener.validate("api-demo", roots: roots)?.path == root.appendingPathComponent("api-demo").path)
        assert(ProjectOpener.validate("..", roots: roots) == nil, "..")
        assert(ProjectOpener.validate(".", roots: roots) == nil, ".")
        assert(ProjectOpener.validate(".oculto", roots: roots) == nil, "começa com ponto")
        assert(ProjectOpener.validate("api-demo/sub", roots: roots) == nil, "só filho direto")
        assert(ProjectOpener.validate("semgit", roots: roots) == nil, "sem .git")
        assert(ProjectOpener.validate("atalho", roots: roots) == nil, "link para fora")
        assert(ProjectOpener.validate("naoexiste", roots: roots) == nil)
        assert(ProjectOpener.validate("", roots: roots) == nil)

        // no máximo 1 abertura por pergunta
        var opened: [URL] = []
        var o = ProjectOpener(roots: roots) { opened.append($0) }
        assert(o.open("api-demo", ask: "q1").hasPrefix("Abri"))
        assert(o.open("api-demo", ask: "q1").contains("1 por pergunta"))
        assert(o.open("api-demo", ask: "q2").hasPrefix("Abri"))
        assert(o.open("..", ask: "q3").contains("Não posso"))
        assert(opened.count == 2)
        try? fm.removeItem(at: base)
        print("ok")
    }
}
