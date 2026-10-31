// Uso: swiftc -parse-as-library Sources/iLand/SuspectTracker.swift Sources/iLand/Projects.swift Sources/iLand/Prefs.swift Sources/iLand/Resume.swift test_resume.swift -o /tmp/t_resume && /tmp/t_resume
import Foundation

@main struct ResumeCheck {
    static func main() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        // quando avisar: voltou depois de 1 h; nunca visto (ou visto há mais de 7 dias) não avisa
        assert(Resume.shouldNotify(lastSeen: now.addingTimeInterval(-3600), now: now))
        assert(!Resume.shouldNotify(lastSeen: now.addingTimeInterval(-3599), now: now))
        assert(!Resume.shouldNotify(lastSeen: nil, now: now))
        assert(!Resume.shouldNotify(lastSeen: now.addingTimeInterval(-8 * 86400), now: now))

        // permanência: só avisa depois de 5 min seguidos no projeto; passagem rápida não conta como visita
        var g = ResumeGate(lastSeen: ["/p/a": now.addingTimeInterval(-7200)])
        assert(g.observe(project: "/p/a", now: now) == nil, "acabou de entrar")
        assert(g.observe(project: "/p/b", now: now.addingTimeInterval(10)) == nil, "passou rápido por b")
        assert(g.observe(project: "/p/a", now: now.addingTimeInterval(20)) == nil)
        assert(g.observe(project: "/p/a", now: now.addingTimeInterval(20 + 299)) == nil, "4 min 59 s")
        assert(g.observe(project: "/p/a", now: now.addingTimeInterval(20 + 300)) == "/p/a", "5 min seguidos: avisa")
        assert(g.observe(project: "/p/a", now: now.addingTimeInterval(20 + 400)) == nil, "uma vez por estadia")
        // sair e voltar logo não avisa de novo (a estadia de 5 min conta como visita)
        _ = g.observe(project: "/p/b", now: now.addingTimeInterval(500))
        _ = g.observe(project: "/p/a", now: now.addingTimeInterval(600))
        assert(g.observe(project: "/p/a", now: now.addingTimeInterval(1000)) == nil, "visto há pouco")
        // passagem rápida por um projeto parado não reseta a contagem de 1 h dele
        var h = ResumeGate(lastSeen: ["/p/c": now.addingTimeInterval(-7200)])
        _ = h.observe(project: "/p/c", now: now)                       // passa 30 s
        _ = h.observe(project: "/p/d", now: now.addingTimeInterval(30))
        _ = h.observe(project: "/p/c", now: now.addingTimeInterval(600))
        assert(h.observe(project: "/p/c", now: now.addingTimeInterval(900)) == "/p/c", "a passagem não contou como visita")
        // nunca visto: não avisa; sem projeto (nil) quebra a estadia
        var k = ResumeGate(lastSeen: [:])
        _ = k.observe(project: "/p/e", now: now)
        assert(k.observe(project: "/p/e", now: now.addingTimeInterval(400)) == nil)

        // "Em progresso" do ESTADO.md: 1º item, mascarado e cortado
        let estado = """
        # Estado
        ## Concluído
        - coisa velha
        ## Em progresso
        - Fila de propostas: falta o teste do PUT com dev@example.com e o deploy.
        - outra
        ## Backlog
        - x
        """
        assert(Resume.inProgress(fromEstado: estado) == "Fila de propostas: falta o teste do PUT com [email] e o deploy.")
        assert(Resume.inProgress(fromEstado: "# nada\n## Em progresso\n\n## Backlog\n- x") == nil)
        assert(Resume.inProgress(fromEstado: "## Em progresso\n- " + String(repeating: "a", count: 400))?.count == 200)

        // git status --porcelain: conta arquivos
        assert(Resume.changedFiles(porcelain: " M a.swift\n?? b.swift\n") == 2)
        assert(Resume.changedFiles(porcelain: "") == 0)

        // texto curto para o cartão
        let info = Resume.Info(project: "/p/project-a", lastPrompt: "arruma o changelog", inProgress: nil, changedFiles: 3)
        assert(info.lines == ["Último pedido ao Claude: arruma o changelog", "3 arquivos alterados"], "\(info.lines)")
        assert(Resume.Info(project: "/p/x", lastPrompt: nil, inProgress: nil, changedFiles: 0).lines == ["Sem pistas guardadas deste projeto."])
        print("ok")
    }
}
