import Foundation

/// Bloco de notas com salvamento automático (~/Library/Application Support/iLand/notes.txt, pasta 0700, arquivo 0600).
final class NotesModel: ObservableObject {
    @Published var text = "" {
        didSet {
            if text.count > Self.maxLength { text = String(text.prefix(Self.maxLength)); return }   // limite visível: não corta só no disco
            scheduleSave()
        }
    }
    private let file: URL
    private var work: DispatchWorkItem?
    private var loading = true
    static let maxLength = 200_000

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLand")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        file = dir.appendingPathComponent("notes.txt")
        text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        loading = false
    }

    /// Salva 0,6 s depois da última tecla.
    private func scheduleSave() {
        guard !loading else { return }
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func saveNow() {
        let t = String(text.prefix(Self.maxLength))
        try? t.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
