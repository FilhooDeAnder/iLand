import Foundation
import AppKit

/// Arquivo guardado na prateleira: só a referência (caminho), nada é copiado.
struct ShelfItem: Codable, Identifiable, Equatable {
    let id: UUID
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
}

enum ShelfList {
    static let maxItems = 24

    /// Novos na frente, sem repetir caminho, no máximo `max` (os mais antigos saem).
    static func adding(_ urls: [URL], to items: [ShelfItem], max: Int = maxItems) -> [ShelfItem] {
        var out = items
        for u in urls where u.isFileURL {
            let p = u.standardizedFileURL.path
            guard !p.isEmpty, p != "/" else { continue }
            out.removeAll { $0.path == p }
            out.insert(ShelfItem(id: UUID(), path: p), at: 0)
        }
        return Array(out.prefix(max))
    }
}

/// Prateleira de arquivos do notch. Lista salva em ~/Library/Application Support/iLand/shelf.json (pasta 0700).
final class ShelfModel: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    private let file: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLand")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)   // também se a pasta já existia
        file = dir.appendingPathComponent("shelf.json")
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([ShelfItem].self, from: data) { items = list }
    }

    func add(_ urls: [URL]) { items = ShelfList.adding(urls, to: items); save() }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func clear() { items = []; save() }
    func exists(_ item: ShelfItem) -> Bool { FileManager.default.fileExists(atPath: item.path) }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
