// Uso: swiftc -parse-as-library Sources/iLand/Shelf.swift Sources/iLand/Providers.swift Sources/iLand/ClaudeChat.swift Sources/iLand/Prefs.swift Sources/iLand/Projects.swift Sources/iLand/SuspectTracker.swift test_shelf.swift -o /tmp/t_shelf && /tmp/t_shelf
import Foundation

@main struct ShelfCheck {
    static func main() {
        // Prateleira: novos na frente, sem repetir, com limite.
        let a = URL(fileURLWithPath: "/tmp/a.txt"), b = URL(fileURLWithPath: "/tmp/b.txt"), c = URL(fileURLWithPath: "/tmp/c.txt")
        var items = ShelfList.adding([a, b], to: [])
        assert(items.map(\.name) == ["b.txt", "a.txt"], "o último a entrar fica na frente")
        items = ShelfList.adding([a], to: items)
        assert(items.map(\.name) == ["a.txt", "b.txt"], "repetido sobe para a frente, sem duplicar")
        items = ShelfList.adding([c, URL(string: "https://x.com/y")!, URL(fileURLWithPath: "/")], to: items, max: 2)
        assert(items.map(\.name) == ["c.txt", "a.txt"], "só arquivos, sem a raiz, com limite: \(items.map(\.name))")

        // Persistência em pasta temporária.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iland-shelf-test-\(UUID().uuidString)")
        let m = ShelfModel(directory: dir)
        m.add([a, b])
        assert(ShelfModel(directory: dir).items.map(\.name) == ["b.txt", "a.txt"], "recarrega o que foi salvo")
        let attrs = try! FileManager.default.attributesOfItem(atPath: dir.path)
        assert((attrs[.posixPermissions] as! Int) & 0o077 == 0, "pasta só do usuário")
        m.remove(m.items[0].id); assert(m.items.map(\.name) == ["a.txt"])
        m.clear(); assert(ShelfModel(directory: dir).items.isEmpty)
        try? FileManager.default.removeItem(at: dir)

        // Claude: pergunta como UM argumento depois de "--", sem ferramentas, sem sessão, sem configs do usuário.
        let args = ClaudeCLI.arguments(prompt: "-1 é um número? $(rm -rf ~) `x` ; &", model: "haiku")
        assert(args.last == "-1 é um número? $(rm -rf ~) `x` ; &" && args[args.count - 2] == "--", "texto do usuário sempre o último argv")
        assert(zip(args, args.dropFirst()).contains { $0 == "--tools" && $1 == "" }, "sem ferramentas")
        assert(args.contains("--no-session-persistence") && args.contains("-p") && args.contains("haiku"))
        assert(zip(args, args.dropFirst()).contains { $0 == "--setting-sources" && $1 == "" })
        assert(CodexCLI.arguments(prompt: "-x", model: "gpt-5", system: "s").suffix(2).first == "--", "Codex: texto depois de --")
        assert(LLM.safeModel("glm-5.3:cloud") && !LLM.safeModel("--dangerously") && !LLM.safeModel("a b"))
        print("ok")
    }
}
