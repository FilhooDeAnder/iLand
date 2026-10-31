// Uso: swiftc -parse-as-library Sources/iLand/UsageFetcher.swift Sources/iLand/Providers.swift Sources/iLand/ClaudeChat.swift Sources/iLand/Prefs.swift Sources/iLand/Projects.swift Sources/iLand/SuspectTracker.swift test_usage.swift -o /tmp/t_usage && /tmp/t_usage
// JSON inventado, sem credencial real.
import Foundation

@main struct UsageCheck {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let d = { (s: String) in s.data(using: .utf8)! }

        // Resposta normal (formato real: utilization 0-100, resets_at ISO com microssegundos, campos extras).
        let ok = UsageFetcher.parse(d(#"{"five_hour":{"utilization":42.4,"resets_at":"2027-02-15T08:00:00.679299+00:00","used_dollars":null},"seven_day":{"utilization":19.0,"resets_at":"2027-02-17T08:00:00+00:00"},"limits":{}}"#), now: now)!
        assert(ok.updatedAt == now.timeIntervalSince1970)
        assert(ClaudeUsage.percent(ok.fiveHour, now: now) == 42 && ClaudeUsage.percent(ok.sevenDay, now: now) == 19)
        assert(ok.fiveHour?.resetsAt == UsageFetcher.epoch("2027-02-15T08:00:00Z")!, "fração descartada")
        assert(ok.sevenDay?.resetsAt != nil)
        // Janela vencida = 0%.
        assert(ClaudeUsage.percent(ok.fiveHour, now: Date(timeIntervalSince1970: ok.fiveHour!.resetsAt! + 1)) == 0)

        // resets_at null e janela faltando.
        let partial = UsageFetcher.parse(d(#"{"five_hour":{"utilization":7,"resets_at":null}}"#), now: now)!
        assert(partial.fiveHour?.resetsAt == nil && ClaudeUsage.percent(partial.fiveHour, now: now) == 7)
        assert(partial.sevenDay == nil && ClaudeUsage.percent(partial.sevenDay, now: now) == nil)

        // Formato mudou / lixo = nil.
        assert(UsageFetcher.parse(d(#"{"five_hour":{},"seven_day":{}}"#)) == nil)
        assert(UsageFetcher.parse(d(#"{"error":"x"}"#)) == nil)
        assert(UsageFetcher.parse(d("<html>")) == nil)

        // Credencial: válida, expirada, sem campo, não-JSON.
        let ms = now.timeIntervalSince1970 * 1000
        assert(UsageFetcher.token(fromCredential: d(#"{"claudeAiOauth":{"accessToken":"fake-abc","refreshToken":"r","expiresAt":\#(ms + 60_000)}}"#), now: now) == "fake-abc")
        assert(UsageFetcher.token(fromCredential: d(#"{"claudeAiOauth":{"accessToken":"fake-abc","expiresAt":\#(ms - 1)}}"#), now: now) == nil, "expirado")
        assert(UsageFetcher.token(fromCredential: d(#"{"claudeAiOauth":{"expiresAt":\#(ms + 60_000)}}"#), now: now) == nil)
        assert(UsageFetcher.token(fromCredential: d("nope"), now: now) == nil)

        // Precedência: API recente > arquivo > o mais novo dos defasados > nil.
        let t = now.timeIntervalSince1970
        let api = ClaudeUsage(updatedAt: t - 60), file = ClaudeUsage(updatedAt: t - 10)
        let oldApi = ClaudeUsage(updatedAt: t - 3600), oldFile = ClaudeUsage(updatedAt: t - 1800)
        assert(ClaudeUsage.pick(api: api, file: file, now: now)?.updatedAt == api.updatedAt, "API recente ganha")
        assert(ClaudeUsage.pick(api: oldApi, file: file, now: now)?.updatedAt == file.updatedAt, "API velha perde p/ arquivo")
        assert(ClaudeUsage.pick(api: oldApi, file: oldFile, now: now)?.updatedAt == oldFile.updatedAt)
        assert(ClaudeUsage.pick(api: oldApi, file: nil, now: now)?.isStale(now: now) == true, "defasado = apagado")
        assert(ClaudeUsage.pick(api: nil, file: nil, now: now) == nil)
        print("ok")
    }
}
