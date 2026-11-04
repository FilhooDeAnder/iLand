// iLand: reads the macOS "now playing" session and sends play, pause, next, previous and seek.
// This code runs inside /usr/bin/perl (see nowplaying.pl), not inside the app.
// build.sh compiles it to Contents/Resources/nowplaying.dylib.
//
// Modes (the argument after the dylib path):
//   watch            prints one JSON line at start and one at each change. Exits when the app closes.
//   toggle | next | previous
//   seek <seconds>
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private typealias InfoBlock = @convention(block) (CFDictionary?) -> Void
private typealias GetInfo = @convention(c) (DispatchQueue, @escaping InfoBlock) -> Void
private typealias PIDBlock = @convention(block) (Int32) -> Void
private typealias GetPID = @convention(c) (DispatchQueue, @escaping PIDBlock) -> Void
private typealias PlayingBlock = @convention(block) (Bool) -> Void
private typealias GetPlaying = @convention(c) (DispatchQueue, @escaping PlayingBlock) -> Void
private typealias Register = @convention(c) (DispatchQueue) -> Void
private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
private typealias SetElapsed = @convention(c) (Double) -> Void

private let mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

private func symbol<T>(_ name: String, _: T.Type) -> T? {
    guard let mr, let p = dlsym(mr, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private let queue = DispatchQueue(label: "iland.nowplaying")            // reads, one at a time
private let replies = DispatchQueue(label: "iland.nowplaying.replies")  // MediaRemote answers here (read() waits on `queue`)
private var lastArtwork: Data?
private var lastTrack = ""

/// Cover art reduced to 256 px JPEG, so a 3000 px PNG does not go through the pipe.
private func thumbnail(_ data: Data) -> Data? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary)
    else { return nil }
    let out = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(dst) ? out as Data : nil
}

private func emit(_ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
    FileHandle.standardOutput.write(d + Data("\n".utf8))
}

/// Reads the session and prints one line. The cover goes only when it changed ("" = no cover).
private func read() {
    guard let getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", GetInfo.self),
          let getPID = symbol("MRMediaRemoteGetNowPlayingApplicationPID", GetPID.self),
          let getPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", GetPlaying.self)
    else { return emit(["error": "MediaRemote unavailable"]) }
    let group = DispatchGroup()
    var info: [String: Any] = [:], pid: Int32 = 0, playing = false
    group.enter(); getInfo(replies) { d in info = (d as? [String: Any]) ?? [:]; group.leave() }
    group.enter(); getPID(replies) { p in pid = p; group.leave() }
    group.enter(); getPlaying(replies) { p in playing = p; group.leave() }
    guard group.wait(timeout: .now() + 2) == .success else { return }

    var o: [String: Any] = ["playing": playing]
    let k = "kMRMediaRemoteNowPlayingInfo"
    for (key, name) in [("title", "Title"), ("artist", "Artist"), ("album", "Album")] { o[key] = info[k + name] as? String }
    for (key, name) in [("duration", "Duration"), ("elapsed", "ElapsedTime"), ("rate", "PlaybackRate")] { o[key] = info[k + name] as? Double }
    if let at = info[k + "Timestamp"] as? Date { o["at"] = at.timeIntervalSince1970 }
    if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
        o["app"] = app.localizedName
        o["bundle"] = app.bundleIdentifier
    }
    // The cover often comes a moment after the title. A missing cover on the same track is not a change.
    let track = [o["title"], o["artist"], o["album"]].map { ($0 as? String) ?? "" }.joined(separator: "\u{1F}")
    let art = (info[k + "ArtworkData"] as? Data).flatMap(thumbnail) ?? (track == lastTrack ? lastArtwork : nil)
    lastTrack = track
    if art != lastArtwork {
        lastArtwork = art
        o["artwork"] = art?.base64EncodedString() ?? ""
    }
    emit(o)
}

private func watch() {
    guard let register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", Register.self) else {
        return emit(["error": "MediaRemote unavailable"])
    }
    register(queue)
    // Many notifications come together when a track changes: one read 0.15 s after the last one.
    var pending: DispatchWorkItem?
    let schedule = {
        pending?.cancel()
        let w = DispatchWorkItem { read() }
        pending = w
        queue.asyncAfter(deadline: .now() + 0.15, execute: w)
    }
    for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                 "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                 "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"] {
        NotificationCenter.default.addObserver(forName: NSNotification.Name(name), object: nil, queue: nil) { _ in queue.async(execute: schedule) }
    }
    queue.async(execute: schedule)
    // The app closed (parent is launchd): stop. A write to a closed pipe also ends the process (SIGPIPE).
    let parent = getppid()
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in if getppid() != parent { exit(0) } }
    RunLoop.main.run()
}

/// Commands of MediaRemote: 2 toggle play/pause, 4 next track, 5 previous track.
private func send(_ mode: String, _ arg: String?) -> Int32 {
    switch mode {
    case "toggle", "next", "previous":
        guard let cmd = symbol("MRMediaRemoteSendCommand", SendCommand.self) else { return 1 }
        return cmd(["toggle": 2, "next": 4, "previous": 5][mode]!, nil) ? 0 : 1
    case "seek":
        guard let s = arg.flatMap(Double.init), s.isFinite, s >= 0,
              let seek = symbol("MRMediaRemoteSetElapsedTime", SetElapsed.self) else { return 2 }
        seek(s)
        return 0
    default: return 2
    }
}

@_cdecl("iland_nowplaying_main")
public func ilandNowPlayingMain() {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(where: { $0.hasSuffix(".dylib") }), i + 1 < args.count else { exit(2) }
    let mode = args[i + 1]
    if mode == "watch" { watch() }
    let status = send(mode, i + 2 < args.count ? args[i + 2] : nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))   // the command goes by XPC: exit too soon and it is lost
    exit(status)
}
