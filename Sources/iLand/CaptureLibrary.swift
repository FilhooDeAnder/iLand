import SwiftUI
import AppKit
import ImageIO

/// Biblioteca: as capturas salvas na pasta dos ajustes, com busca, três tamanhos de bloco e lista.
final class CaptureLibrary: ObservableObject {
    struct Item: Identifiable, Equatable { let url: URL; let date: Date; let bytes: Int; var id: URL { url } }

    static let shared = CaptureLibrary()
    private var window: NSWindow?
    @Published private(set) var items: [Item] = []

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    /// Imagens da pasta, da mais nova para a mais antiga. Só lê o nível da pasta, sem entrar nas subpastas.
    static func list(in folder: URL) -> [Item] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Item? in
            guard imageExtensions.contains(url.pathExtension.lowercased()), let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return Item(url: url, date: v.contentModificationDate ?? .distantPast, bytes: v.fileSize ?? 0)
        }.sorted { $0.date > $1.date }
    }

    func reload() { items = Self.list(in: CapturePrefs.saveFolder) }

    func show(open: @escaping (URL) -> Void) {
        reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Capturas"; w.titlebarAppearsTransparent = true; w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua); w.minSize = NSSize(width: 520, height: 360)
            w.contentView = NSHostingView(rootView: CaptureLibraryView(library: self, open: open))
            w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Miniaturas em memória (a pasta pode ter centenas de arquivos).
private enum Thumbnails {
    static let cache = NSCache<NSURL, NSImage>()
    static func image(_ url: URL, side: CGFloat) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side * 2, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

private struct CaptureLibraryView: View {
    @ObservedObject var library: CaptureLibrary
    let open: (URL) -> Void
    @State private var query = ""
    @AppStorage("capLibraryLayout") private var layout = "medium"

    private var filtered: [CaptureLibrary.Item] {
        query.isEmpty ? library.items : library.items.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) }
    }
    private var side: CGFloat { layout == "small" ? 110 : (layout == "large" ? 260 : 170) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Buscar", text: $query).textFieldStyle(.plain)
                Picker("", selection: $layout) {
                    Image(systemName: "list.bullet").tag("list"); Image(systemName: "square.grid.3x3").tag("small")
                    Image(systemName: "square.grid.2x2").tag("medium"); Image(systemName: "square.grid.2x2.fill").tag("large")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Button { NSWorkspace.shared.open(CapturePrefs.saveFolder) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("Abrir a pasta no Finder")
                Button { library.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Atualizar")
            }
            .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 10)
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 30)).foregroundColor(.secondary)
                    Text(library.items.isEmpty ? "Nenhuma captura na pasta." : "Nada encontrado.").foregroundColor(.secondary)
                    if library.items.isEmpty { Text(CapturePrefs.saveFolder.path).font(.caption).foregroundColor(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == "list" {
                List(filtered) { item in
                    HStack(spacing: 12) {
                        thumb(item, 44).frame(width: 44, height: 44)
                        VStack(alignment: .leading) { Text(item.url.lastPathComponent); Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.secondary) }
                        Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).font(.caption).foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle()).onTapGesture(count: 2) { open(item.url) }.contextMenu { menu(item) }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: side), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { item in
                            thumb(item, side).frame(height: side * 0.72)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                                .overlay(alignment: .bottomLeading) { Text(item.date.formatted(date: .omitted, time: .shortened)).font(.caption2).padding(4).background(.black.opacity(0.55)).cornerRadius(4).padding(5) }
                                .onTapGesture(count: 2) { open(item.url) }.contextMenu { menu(item) }.help(item.url.lastPathComponent)
                        }
                    }.padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func thumb(_ item: CaptureLibrary.Item, _ side: CGFloat) -> some View {
        Group {
            if let img = Thumbnails.image(item.url, side: side) { Image(nsImage: img).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundColor(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func menu(_ item: CaptureLibrary.Item) -> some View {
        Button("Abrir no editor") { open(item.url) }
        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Copiar imagem") { if let img = NSImage(contentsOf: item.url) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img]) } }
        Divider()
        Button("Mover para a Lixeira") { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil); library.reload() }
    }
}
