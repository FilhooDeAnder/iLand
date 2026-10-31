import SwiftUI

/// Página "Área de transferência": pesquisar, fixar, copiar de novo e limpar links.
struct ClipboardPage: View {
    @ObservedObject var clip: ClipboardModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(secondary)
                TextField("Pesquisar no histórico", text: $clip.query).textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                Button(clip.autoClean ? "Limpar links: sim" : "Limpar links: não") { clip.autoClean.toggle() }
                    .buttonStyle(ChipStyle()).help("Remove utm_, fbclid, gclid... dos links copiados, automaticamente")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))

            let items = clip.visible
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.09))
                if items.isEmpty {
                    Text(clip.query.isEmpty ? "Copie algo e ele aparece aqui. Senhas de gerenciadores não entram." : "Nada encontrado.")
                        .font(.system(size: 11)).foregroundColor(secondary).padding(10)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) { ForEach(items) { ClipRow(item: $0, clip: clip) } }.padding(4)
                    }
                }
            }
            .frame(height: 104)
        }
        .padding(.horizontal, 18).padding(.top, NotchLayout.ear).padding(.bottom, 22)
    }
}

struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clip: ClipboardModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(item.pinned ? .orange : secondary).frame(width: 14)
            Text(clip.copiedID == item.id ? "Copiado ✓" : item.preview).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                .foregroundColor(clip.copiedID == item.id ? .green : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                if item.kind == .url, URLCleaner.clean(item.text) != item.text {
                    Button("limpar") { clip.clean(item) }.buttonStyle(ChipStyle()).help("Tirar os parâmetros de rastreio do link")
                }
                Button { clip.togglePin(item) } label: { Image(systemName: item.pinned ? "pin.slash" : "pin").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(secondary).help(item.pinned ? "Desafixar" : "Fixar (fica salvo)")
                Button { clip.remove(item) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundColor(secondary).help("Apagar do histórico")
            } else {
                Text(Fmt.age(Date().timeIntervalSince(item.date))).font(.system(size: 9)).foregroundColor(secondary)
            }
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { clip.copy(item) }
        .help(item.text.count > 200 ? String(item.text.prefix(200)) + "…" : item.text)
    }

    private var icon: String {
        item.pinned ? "pin.fill" : (item.kind == .url ? "link" : (item.kind == .files ? "doc" : "text.alignleft"))
    }
}
