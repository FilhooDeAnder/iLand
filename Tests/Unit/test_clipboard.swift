// Uso: swiftc -parse-as-library Sources/iLand/Clipboard.swift Tests/Unit/test_clipboard.swift -o /tmp/t_clip && /tmp/t_clip
import Foundation

@main struct ClipboardCheck {
    static func main() {
        // Links: tira rastreio, mantém o resto, ignora o que não é link.
        assert(URLCleaner.clean("https://a.com/p?id=7&utm_source=x&fbclid=abc#frag") == "https://a.com/p?id=7#frag")
        assert(URLCleaner.clean("https://a.com/p?utm_medium=x&gclid=1") == "https://a.com/p", "sem parâmetros sobrando, some o ?")
        assert(URLCleaner.clean("https://a.com/watch?v=abc&si=zzz") == "https://a.com/watch?v=abc")
        assert(URLCleaner.clean("  https://a.com/x  ") == "https://a.com/x")
        assert(URLCleaner.clean("ftp://a.com/x") == nil && URLCleaner.clean("dois links http://a.com http://b.com") == nil && URLCleaner.clean("texto") == nil)

        // Histórico: topo, sem repetir, limite, fixados.
        var h = ClipHistory(); h.maxItems = 3
        let t0 = Date(timeIntervalSince1970: 1_000)
        for s in ["a", "b", "c"] { h.add(.text, s, now: t0) }
        assert(h.items.map(\.text) == ["c", "b", "a"])
        h.add(.text, "a", now: t0); assert(h.items.map(\.text) == ["a", "c", "b"], "repetido sobe")
        h.togglePin(h.items.last!.id)   // fixa "b"
        h.add(.text, "d", now: t0); h.add(.text, "e", now: t0)
        assert(h.items.map(\.text).contains("b") && h.items.filter { !$0.pinned }.count == 3, "fixado nunca sai; soltos até o limite: \(h.items.map(\.text))")
        assert(h.visible(query: "").first?.text == "b", "fixados primeiro")
        h.add(.text, String(repeating: "x", count: ClipHistory.maxLength + 1)); assert(!h.items.contains { $0.text.hasPrefix("xxxx") }, "texto gigante não entra")
        h.add(.text, ""); assert(!h.items.contains { $0.text.isEmpty })
        assert(h.visible(query: "E").map(\.text) == ["e"] && h.visible(query: "zz").isEmpty, "busca sem diferenciar maiúsculas")
        var acc = ClipHistory(); acc.add(.text, "Ação rápida"); assert(acc.visible(query: "acao").count == 1, "sem diferenciar acentos")
        h.clearUnpinned(); assert(h.items.map(\.text) == ["b"])

        // Privacidade: gerenciadores de senha e tipos sensíveis nunca entram.
        assert(ClipboardPrivacy.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], frontApp: nil))
        assert(ClipboardPrivacy.shouldSkip(types: ["public.utf8-plain-text"], frontApp: "com.1password.1password"))
        assert(ClipboardPrivacy.shouldSkip(types: [], frontApp: "com.bitwarden.desktop"))
        assert(!ClipboardPrivacy.shouldSkip(types: ["public.utf8-plain-text"], frontApp: "com.apple.Safari"))

        // Persistência: só os fixados vão para o disco.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iland-clip-test-\(UUID().uuidString)")
        let m = ClipboardModel(directory: dir)
        assert(m.history.items.isEmpty)
        try? FileManager.default.removeItem(at: dir)
        print("ok")
    }
}
