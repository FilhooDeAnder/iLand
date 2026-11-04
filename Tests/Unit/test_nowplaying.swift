// Uso: swiftc -parse-as-library Sources/iLand/NowPlayingTrack.swift Tests/Unit/test_nowplaying.swift -o /tmp/t_np && /tmp/t_np
import Foundation

@main struct NowPlayingCheck {
    static func main() {
        func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

        // Linha completa: campos, posição andando com o tempo e parando no fim da música.
        let r = Track.parse(line(["title": "Song", "artist": "A", "app": "Spotify", "duration": 200.0, "elapsed": 10.0,
                                  "rate": 1.0, "at": 1000.0, "playing": true, "artwork": Data([1, 2]).base64EncodedString()]))!
        let t = r.track!
        assert(t.title == "Song" && t.artist == "A" && t.app == "Spotify" && r.artwork == Data([1, 2]))
        assert(t.position(Date(timeIntervalSince1970: 1030)) == 40)
        assert(t.position(Date(timeIntervalSince1970: 9999)) == 200)
        var paused = t; paused.playing = false
        assert(paused.position(Date(timeIntervalSince1970: 1030)) == 10)   // pausada: não anda

        // Sem título = nada tocando. Sem "artwork" = capa igual à anterior. "" = sem capa.
        let none = Track.parse(line(["playing": false]))!
        assert(none.track == nil && none.artwork == nil)
        assert(Track.parse(line(["title": "x", "artwork": ""]))!.artwork == Data())

        // Lixo, erro do ajudante, linha grande demais e números ruins não quebram.
        assert(Track.parse(Data("{x".utf8)) == nil && Track.parse(line(["error": "MediaRemote unavailable"])) == nil)
        assert(Track.parse(Data(count: Track.maxLine + 1)) == nil)
        let bad = Track.parse(line(["title": "Live", "duration": 0.0, "elapsed": -5.0]))!.track!
        assert(bad.duration == nil && bad.elapsed == 0)   // ao vivo: sem duração
        print("ok")
    }
}
