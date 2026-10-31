import SwiftUI

/// Página "Som": volume e dispositivo de saída, e volume do microfone.
struct SoundPage: View {
    @ObservedObject var sound: SoundModel

    var body: some View {
        VStack(spacing: 8) {
            row(icon: sound.outMuted || (sound.outVolume ?? 1) == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", title: "Saída",
                value: sound.outVolume, muted: sound.outMuted, onMute: sound.toggleOutMute, onChange: sound.setOutVolume) {
                Menu {
                    ForEach(sound.outputs) { d in Button(d.name) { sound.setOutput(d.id) } }
                } label: {
                    Text(sound.outputName).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton).frame(width: 130, alignment: .trailing)
            }
            row(icon: sound.inMuted ? "mic.slash.fill" : "mic.fill", title: "Microfone",
                value: sound.inVolume, muted: sound.inMuted, onMute: sound.toggleInMute, onChange: sound.setInVolume) {
                Text(sound.inputName ?? "—").font(.system(size: 11)).foregroundColor(secondary).lineLimit(1).truncationMode(.middle)
                    .frame(width: 130, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18).padding(.top, NotchLayout.ear).padding(.bottom, 22)
        .frame(height: 112 + NotchLayout.ear + 22, alignment: .top)
    }

    private func row<Trailing: View>(icon: String, title: String, value: Float?, muted: Bool, onMute: @escaping () -> Void,
                                     onChange: @escaping (Float) -> Void, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Button(action: onMute) { Image(systemName: icon).font(.system(size: 14)).frame(width: 20) }
                .buttonStyle(.plain).foregroundColor(muted ? .orange : .white).help(muted ? "Ligar o som" : "Silenciar")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10)).foregroundColor(secondary)
                if let value {
                    Slider(value: Binding(get: { Double(value) }, set: { onChange(Float($0)) }), in: 0...1, onEditingChanged: sound.editing)
                        .tint(muted ? .orange : .white)
                } else {
                    Text("sem controle de volume neste dispositivo").font(.system(size: 10)).foregroundColor(secondary)
                }
            }
            Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(.system(size: 12)).monospacedDigit()
                .foregroundColor(muted ? .orange : .white).frame(width: 38, alignment: .trailing)
            trailing()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.09)))
    }
}
