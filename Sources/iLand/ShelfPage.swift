import SwiftUI
import UniformTypeIdentifiers

/// Página "Prateleira": solte arquivos aqui para guardar; clique abre, arraste para levar, × remove da prateleira (o arquivo não é apagado).
struct ShelfPage: View {
    @ObservedObject var shelf: ShelfModel
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(targeted ? 0.2 : 0.09))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .opacity(shelf.items.isEmpty || targeted ? 1 : 0)
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                    Text("Arraste arquivos aqui para guardar").font(.system(size: 11))
                }
                .foregroundColor(secondary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                        ForEach(shelf.items) { ShelfTile(item: $0, shelf: shelf) }
                    }
                    .padding(8)
                }
            }
        }
        .frame(height: 112)
        .padding(.horizontal, 18).padding(.top, NotchLayout.ear).padding(.bottom, 22)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            let group = DispatchGroup()
            let lock = DispatchQueue(label: "iland.shelf.drop")   // os callbacks chegam em threads diferentes
            var urls: [URL] = []
            for p in providers {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { lock.sync { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { shelf.add(lock.sync { urls }) }
            return true
        }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfModel
    @State private var hover = false

    var body: some View {
        let ok = shelf.exists(item)
        VStack(spacing: 2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 34, height: 34)
            Text(item.name).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center)
        }
        .foregroundColor(.white)
        .opacity(ok ? 1 : 0.35)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { shelf.remove(item.id) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundColor(secondary).help("Tirar da prateleira (o arquivo não é apagado)")
            }
        }
        .onHover { hover = $0 }
        .onTapGesture { if ok { NSWorkspace.shared.open(item.url) } }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .help(ok ? item.path : "Arquivo não encontrado: \(item.path)")
    }
}
