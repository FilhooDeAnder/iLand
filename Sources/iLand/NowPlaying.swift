import AppKit
import Combine
import SwiftUI

/// Lê o "tocando agora" pelo ajudante (Helpers/nowplaying.*): o `/usr/bin/perl` carrega a nowplaying.dylib.
/// Desde o macOS 15.4 o sistema só entrega esses dados a processos com a assinatura da Apple, e o perl tem.
/// O ajudante fica aberto e manda uma linha JSON a cada mudança. Se ele cai, volta em 2 s, 4 s… até 60 s.
final class NowPlayingModel: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?

    private var watcher: Process?
    private var buffer = Data()
    private var retry: TimeInterval = 2
    private var stopped = false

    private static let script = Bundle.main.url(forResource: "nowplaying", withExtension: "pl")
    private static let library = Bundle.main.url(forResource: "nowplaying", withExtension: "dylib")

    func start() {
        guard watcher == nil, let script = Self.script, let library = Self.library else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, library.path, "watch"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.receive(d) }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.restart() }
        }
        do { try p.run(); watcher = p } catch { restart() }
    }

    private func restart() {
        watcher = nil
        buffer.removeAll()
        guard !stopped else { return }
        let wait = retry
        retry = min(retry * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.start() }
    }

    private func receive(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let r = Track.parse(Data(line)) else { continue }
            retry = 2
            if let art = r.artwork { artwork = art.isEmpty ? nil : NSImage(data: art) }
            if track != r.track { track = r.track }
        }
        if buffer.count > Track.maxLine { buffer.removeAll() }   // linha sem fim: descarta
    }

    func toggle() { send("toggle") }
    func next() { send("next") }
    func previous() { send("previous") }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        send("seek", String(format: "%.2f", seconds))
    }

    /// Comando curto (o ajudante sai em 0,3 s). A linha nova chega pelo `watch`.
    private func send(_ args: String...) {
        guard let script = Self.script, let library = Self.library else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, library.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// Página "Tocando": capa, nome, barra de tempo e os três botões.
struct NowPlayingPage: View {
    @ObservedObject var player: NowPlayingModel
    @State private var dragging: Double?

    var body: some View {
        Group {
            if let t = player.track {
                HStack(alignment: .center, spacing: 14) {
                    cover(88)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text([t.artist, t.app].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundColor(secondary).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in timeBar(t, ctx.date) }
                        controls(t)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "music.note").font(.system(size: 22)).foregroundColor(secondary)
                    Text("Nada tocando").font(.system(size: 12)).foregroundColor(secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 22)
        .padding(.top, NotchLayout.ear)
        .padding(.bottom, 18)
    }

    private func cover(_ size: CGFloat) -> some View {
        Group {
            if let img = player.artwork { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundColor(secondary) }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func timeBar(_ t: Track, _ now: Date) -> some View {
        let pos = dragging ?? t.position(now)
        HStack(spacing: 8) {
            Text(TimeFmt.clock(pos)).frame(width: 40, alignment: .trailing)
            if let d = t.duration {
                Slider(value: Binding(get: { pos }, set: { dragging = $0 }), in: 0...d) { editing in
                    if !editing, let v = dragging { player.seek(v); dragging = nil }
                }
                .controlSize(.mini)
                Text(TimeFmt.clock(d)).frame(width: 40, alignment: .leading)
            } else { Spacer() }   // transmissão ao vivo: sem duração, sem barra
        }
        .font(.system(size: 10)).monospacedDigit().foregroundColor(secondary)
    }

    private func controls(_ t: Track) -> some View {
        HStack(spacing: 22) {
            button("backward.fill", 14, "Anterior", player.previous)
            button(t.playing ? "pause.fill" : "play.fill", 20, t.playing ? "Pausar" : "Tocar", player.toggle)
            button("forward.fill", 14, "Próxima", player.next)
        }
        .frame(maxWidth: .infinity)
    }

    private func button(_ symbol: String, _ size: CGFloat, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size)).frame(width: 28, height: 24) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// Orelha: capa pequena e três barras que mexem enquanto toca.
struct EarMediaLabel: View {
    @ObservedObject var player: NowPlayingModel
    @State private var up = false

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if let img = player.artwork { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "music.note").font(.system(size: 9)).foregroundColor(secondary) }
            }
            .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3) { i in
                    Capsule().fill(Color.white)
                        .frame(width: 2, height: up ? [10, 6, 12][i] : [4, 9, 5][i])
                        .animation(.easeInOut(duration: [0.45, 0.6, 0.5][i]).repeatForever(autoreverses: true), value: up)
                }
            }
            .frame(height: 12)
        }
        .onAppear { up = true }
    }
}
