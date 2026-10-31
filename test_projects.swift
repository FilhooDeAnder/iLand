// Uso: swiftc -parse-as-library Sources/iLand/SuspectTracker.swift Sources/iLand/Projects.swift Sources/iLand/Prefs.swift test_projects.swift -o /tmp/t_projects && /tmp/t_projects
// Caminhos e linhas no formato real (sem conteúdo de conversa).
import Foundation

@main struct ProjectsCheck {
    static func main() {
        let gits: Set<String> = ["/u/workspace-demo", "/u/workspace-demo/monorepo-demo/api-demo", "/u/Projetos/iLand",
                                 "/u/Projetos/api-demo", "/u/Projetos/demo-api"]
        let exists = { (p: String) in gits.contains(p) }
        // ancestral com .git mais fundo
        assert(ProjectResolver.root(forPath: "/u/workspace-demo/monorepo-demo/api-demo/apps/x.py", exists: exists) == "/u/workspace-demo/monorepo-demo/api-demo")
        assert(ProjectResolver.root(forPath: "/u/workspace-demo/docs/a.md", exists: exists) == "/u/workspace-demo")
        assert(ProjectResolver.root(forPath: "/u/Projetos/iLand", exists: exists) == "/u/Projetos/iLand")
        assert(ProjectResolver.root(forPath: "/tmp/x", exists: exists) == nil)
        assert(ProjectResolver.root(forPath: "file:///u/Projetos/iLand/Sources/a.swift", exists: exists) == "/u/Projetos/iLand", "URL do AXDocument")
        assert(ProjectResolver.root(forPath: "file:///u/Projetos/iLand/Read%20Me.md", exists: exists) == "/u/Projetos/iLand", "URL com espaço codificado")

        // pasta no título do Cursor/VS Code
        assert(ProjectResolver.folderName(fromTitle: "Machines.swift — iLand") == "iLand")
        assert(ProjectResolver.folderName(fromTitle: "● views.py — api-demo — Cursor") == "api-demo")
        assert(ProjectResolver.folderName(fromTitle: "Projetos (Workspace)") == nil)
        assert(ProjectResolver.folderName(fromTitle: "a.swift — Projetos (Workspace)") == nil)
        assert(ProjectResolver.folderName(fromTitle: "iLand") == "iLand", "só a pasta aberta")
        assert(ProjectResolver.folderName(fromTitle: "") == nil)

        // nome -> repositório
        let repos = Array(gits)
        assert(ProjectResolver.match(name: "iLand", repos: repos, recent: nil) == "/u/Projetos/iLand")
        assert(ProjectResolver.match(name: "api-demo", repos: repos, recent: nil) == "api-demo (?)", "ambíguo sem pista")
        assert(ProjectResolver.match(name: "api-demo", repos: repos, recent: ["/u/Projetos/iLand", "/u/workspace-demo/monorepo-demo/api-demo"])
               == "/u/workspace-demo/monorepo-demo/api-demo", "usa o mais recente com caminho")
        assert(ProjectResolver.match(name: "zzz", repos: repos, recent: nil) == nil)
        // pasta de projeto sem .git (project-a, project-b): vale a pasta conhecida
        assert(ProjectResolver.match(name: "project-a", repos: repos + ["/u/Projetos/project-a"], recent: nil) == "/u/Projetos/project-a")
        // Terminal: "pasta — processo — tamanho"
        assert(ProjectResolver.terminalFolder(fromTitle: "iLand — -zsh — 132×46") == "iLand")
        assert(ProjectResolver.terminalFolder(fromTitle: "zsh") == nil)
        assert(ProjectResolver.display("/u/workspace-demo/monorepo-demo/api-demo") == "api-demo")
        assert(ProjectResolver.display("api-demo (?)") == "api-demo (?)")

        // sessões do Claude: fim do arquivo, primeira linha cortada, sdk-cli e sidechain fora
        let tail = """
        ype":"user","cwd":"/cortada"}
        {"type":"user","entrypoint":"claude-desktop","isSidechain":false,"cwd":"/u/Projetos/iLand","timestamp":"2026-10-06T10:40:40.996Z","message":{}}
        {"type":"assistant","entrypoint":"claude-desktop","isSidechain":false,"cwd":"/u/Projetos/iLand","timestamp":"2026-10-06T10:41:00.000Z"}
        {"type":"user","entrypoint":"claude-desktop","isSidechain":true,"cwd":"/u/sub","timestamp":"2026-10-06T10:42:00.000Z"}
        {"type":"last-prompt","lastPrompt":"manda pro dev@example.com o resumo","leafUuid":"x","sessionId":"s"}
        """
        guard let s = ClaudeSessions.latest(tail: tail) else { fatalError("não leu a sessão") }
        assert(s.cwd == "/u/Projetos/iLand" && s.entrypoint == "claude-desktop", "\(s)")
        assert(abs(s.timestamp.timeIntervalSince1970 - 1_791_283_260) < 1, "\(s.timestamp.timeIntervalSince1970)")
        assert(s.lastPrompt == "manda pro [email] o resumo", s.lastPrompt ?? "nil")
        let auto = #"{"type":"user","entrypoint":"sdk-cli","isSidechain":false,"cwd":"/u/x","timestamp":"2026-10-06T10:40:40Z"}"#
        assert(ClaudeSessions.latest(tail: auto) == nil, "automação fora")
        assert(ClaudeSessions.latest(tail: "") == nil)
        print("ok")
    }
}
