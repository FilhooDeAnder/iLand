// Uso: swiftc -parse-as-library Sources/iLand/Updater.swift Sources/iLand/Energy.swift Sources/iLand/AlertEngine.swift Sources/iLand/History.swift Sources/iLand/Providers.swift Sources/iLand/ClaudeChat.swift Sources/iLand/Prefs.swift Sources/iLand/Projects.swift Sources/iLand/SuspectTracker.swift Tests/Unit/test_share.swift -o /tmp/t_share && /tmp/t_share
// Partes do iLand compartilhável: versão do update, host do SSH, papel "provedor:modelo" e eventos do Codex.
import Foundation

@main struct ShareCheck {
    static func main() {
        assert(Updater.isNewer("1.10.0", than: "1.9.2") && Updater.isNewer("v2", than: "1.9.9") && !Updater.isNewer("1.0", than: "1.0.0"))
        assert(!Updater.isNewer("1.2.0-beta", than: "1.2.0") && Updater.isNewer("0.0.1", than: "0.0.0"))

        assert(Prefs.isValidHost("web-demo") && Prefs.isValidHost("ec2-user@192.0.2.5") && Prefs.isValidHost("web.prod_1"))
        for bad in ["-oProxyCommand=x", "a b", "a\"b", "", "x@-y", "a;rm", "@host"] { assert(!Prefs.isValidHost(bad), bad) }

        let d = UserDefaults.standard, key = Role.quick.key, old = d.object(forKey: key)
        d.set("ollama:glm-5.3:cloud", forKey: key)
        assert(Role.quick.choice.provider == .ollama && Role.quick.choice.model == "glm-5.3:cloud", "o modelo do Ollama tem ':'")
        d.set("codex:--yolo", forKey: key)
        assert(Role.quick.choice.model == "gpt-5-codex", "modelo inválido cai no sugerido")
        if let old { d.set(old, forKey: key) } else { d.removeObject(forKey: key) }

        let events = """
        {"type":"thread.started","thread_id":"abc-1"}
        {"type":"item.completed","item":{"id":"1","type":"mcp_tool_call","server":"iland","tool":"day_log","status":"completed"}}
        {"type":"item.completed","item":{"id":"2","type":"agent_message","text":"Oi."}}
        {"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":20}}
        """
        let r = CodexCLI.parse(Data(events.utf8))
        assert(r.threadId == "abc-1" && r.text == "Oi." && r.tools == ["day_log"] && r.tokens == 120 && r.error == nil)
        assert(CodexCLI.tomlString("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"")
        print("ok")
    }
}
