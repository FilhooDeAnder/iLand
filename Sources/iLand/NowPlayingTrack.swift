import Foundation

/// Música (ou vídeo) que o macOS mostra como "tocando agora": Spotify, Music, Tidal, navegador.
struct Track: Equatable {
    var title: String
    var artist = ""
    var album = ""
    var app = ""
    var duration: Double?
    var elapsed: Double = 0
    var rate: Double = 0
    var at = Date()
    var playing = false
    static let maxLine = 1_000_000   // linha do ajudante; a capa de 256 px em JPEG fica bem abaixo disso

    /// Posição agora: o macOS manda o tempo de um instante (`at`) e a velocidade; o resto é conta.
    func position(_ now: Date) -> Double {
        let p = elapsed + (playing ? max(0, now.timeIntervalSince(at)) * rate : 0)
        return duration.map { min(p, $0) } ?? p
    }

    /// Uma linha do ajudante. `track` nil = nada tocando. `artwork`: nil = capa igual à anterior; vazio = sem capa.
    static func parse(_ line: Data) -> (track: Track?, artwork: Data?)? {
        guard line.count <= maxLine,
              let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], o["error"] == nil else { return nil }
        let art = (o["artwork"] as? String).map { Data(base64Encoded: $0) ?? Data() }
        guard let title = o["title"] as? String, !title.isEmpty else { return (nil, art) }
        var t = Track(title: title)
        t.artist = o["artist"] as? String ?? ""
        t.album = o["album"] as? String ?? ""
        t.app = o["app"] as? String ?? ""
        t.duration = (o["duration"] as? Double).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        t.elapsed = max(0, o["elapsed"] as? Double ?? 0)
        t.rate = o["rate"] as? Double ?? 0
        t.at = (o["at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        t.playing = o["playing"] as? Bool ?? false
        return (t, art)
    }
}
