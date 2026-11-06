import Foundation
import AppKit
import Combine

/// Uma linha da lista central. `virtual` = a linha "node_modules (N)" no topo de Projetos.
struct DiskRow: Identifiable {
    let id: String
    let title: String
    let path: String?
    let bytes: UInt64
    let modified: Date?
    let isDir: Bool
    var hint: DiskRules.Hint?
    var virtual = false
    var count = 0
    var enterable: Bool { virtual || isDir }
}

/// Estado da janela Disco: categoria escolhida, trilha de pastas, medidas em cache (por caminho; o DiskModel guarda em disco),
/// as node_modules de ~/Projetos e o histórico. Tudo publicado muda só na main; `du` e `find` rodam em filas de fundo.
final class DiskBrowser: ObservableObject {
    static let nodeKey = "iland:node_modules"
    static let maxRows = 200

    enum NodeScan: Equatable { case idle, finding, measuring(done: Int, of: Int), done, failed }

    let model: DiskModel
    let home = NSHomeDirectory()
    @Published private(set) var categoryID: String? { didSet { rebuildRows() } }
    @Published private(set) var trail: [String] = [] { didSet { rebuildRows() } }
    @Published private(set) var selection: String?
    @Published private(set) var selectedCanTrash = false
    @Published private(set) var rows: [DiskRow] = []
    @Published private(set) var cache: [String: [DiskEntry]] = [:] { didSet { rebuildRows() } }
    @Published private(set) var loading = Set<String>()
    @Published private(set) var failed = Set<String>()
    @Published private(set) var nodeModules: [DiskEntry] = [] { didSet { rebuildRows() } }
    @Published private(set) var nodeScan = NodeScan.idle { didSet { rebuildRows() } }
    @Published private(set) var history: [DiskRules.Snapshot] = []
    @Published private(set) var notice: String?
    @Published private(set) var moving = false

    private let runner = DuRunner()
    private let folderQueue = DispatchQueue(label: "br.com.loop4.iland.disk.folder", qos: .utility)
    private let nodeQueue = DispatchQueue(label: "br.com.loop4.iland.disk.node", qos: .utility)
    private var sink: AnyCancellable?
    private var demo = false
    private var scanGeneration = 0
    private var stale = Set<String>()       // listas em cache que um Mover deixou velhas: mede de novo em segundo plano
    @Published private(set) var refreshing = Set<String>()
    private var folderAt: [String: Date] = [:]   // quando cada pasta em `cache` foi medida
    private var nodeAt: Date?
    private var fromSeed = Set<String>()         // listas que vieram do DiskModel: valem até ele medir de novo
    private var lastSeedAt: Date?
    private var skipNodeCache = false            // "Atualizar" ignora a lista guardada
    private var staleGen: [String: Int] = [:]   // o Mover aumenta: uma medida de fundo que começou antes não vale
    private let refreshQueue = DispatchQueue(label: "br.com.loop4.iland.disk.refresh", qos: .utility)
    private var noSeed = Set<String>()   // pastas mexidas por um Mover: a medida do DiskModel já está velha

    init(model: DiskModel) {
        self.model = model
        refreshHistory()
        // @Published avisa antes de gravar: adia para ler as categorias já novas.
        sink = Publishers.Merge(model.$categories.map { _ in }, model.$cacheLoaded.map { _ in }).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            if self.model.measuredAt != self.lastSeedAt {   // o DiskModel mediu de novo: as listas vindas dele são velhas
                self.lastSeedAt = self.model.measuredAt
                self.fromSeed.forEach { self.cache[$0] = nil }; self.fromSeed = []
            }
            self.refreshHistory()
            self.rebuildRows()
            self.loadCurrent()
        }
    }

    private func refreshHistory() {
        guard !demo else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let h = DiskModel.readHistory()
            DispatchQueue.main.async { if let self, !self.demo { self.history = h } }
        }
    }

    /// Ao fechar a janela: termina o du e o find em curso.
    func stop() { runner.stop(); sink = nil }

    /// "Atualizar" desligado: o du, o find ou uma medida de fundo desta janela, ou a medida das categorias.
    var updating: Bool { measuring || !refreshing.isEmpty || model.measuring || model.moving }

    /// Quando foi medido o que está à vista (a mais velha das pastas).
    var measuredAt: Date? {
        if inNodeList { return nodeAt }
        let paths = trail.last.map { [$0] } ?? current?.paths ?? []
        var dates = paths.compactMap { folderAt[$0] }
        if trail.isEmpty, current?.id == "projects", let n = nodeAt { dates.append(n) }
        return dates.min() ?? (trail.isEmpty ? model.measuredAt : nil)
    }

    // MARK: o que está à vista

    var current: DiskCategory? {
        model.categories.first { $0.id == categoryID } ?? model.categories.filter { $0.bytes > 0 }.max { $0.bytes < $1.bytes }
    }

    var sidebar: [DiskCategory] { model.categories.filter { $0.bytes > 0 || $0.id == categoryID }.sorted { $0.bytes > $1.bytes } }

    var inNodeList: Bool { trail.last == Self.nodeKey }

    /// "Projetos", "anota", … : o caminho para o botão de volta (índice 0 = a categoria).
    var crumbs: [String] {
        [current?.title ?? "Disco"] + trail.map { $0 == Self.nodeKey ? "node_modules" : ($0 as NSString).lastPathComponent }
    }

    var nodeModulesTotal: UInt64 { nodeModules.reduce(0) { $0 + $1.bytes } }

    /// Ordena e monta as linhas uma vez por mudança, não a cada desenho.
    private func rebuildRows() {
        let now = Date()
        func make(_ path: String, _ e: DiskEntry, _ title: String) -> DiskRow {
            DiskRow(id: path, title: title, path: path, bytes: e.bytes, modified: e.modified, isDir: e.isDir,
                    hint: DiskRules.hint(path: path, modified: e.modified, now: now, home: home))
        }
        if inNodeList {
            rows = nodeModules.sorted { $0.bytes > $1.bytes }.prefix(Self.maxRows).map { make($0.path, $0, nodeTitle($0.path)) }
            return
        }
        let paths = trail.last.map { [$0] } ?? current?.paths ?? []
        var list = paths.flatMap { cache[$0] ?? [] }.sorted { $0.bytes > $1.bytes }.prefix(Self.maxRows).map { make($0.path, $0, ($0.path as NSString).lastPathComponent) }
        if trail.isEmpty, current?.id == "projects", nodeScan != .idle {
            list.insert(DiskRow(id: Self.nodeKey, title: "node_modules (\(nodeCount))", path: nil, bytes: nodeModulesTotal, modified: nil, isDir: true,
                                hint: DiskRules.hint(path: "node_modules", modified: nil, now: now, home: home), virtual: true, count: nodeCount), at: 0)
        }
        rows = list
    }

    /// Quantas já foram achadas (durante a medida, o total do find).
    var nodeCount: Int { if case .measuring(_, let of) = nodeScan { return of }; return nodeModules.count }

    var hiddenRows: Int {
        let paths = trail.last.map { [$0] } ?? current?.paths ?? []
        let n = inNodeList ? nodeModules.count : paths.reduce(0) { $0 + (cache[$1]?.count ?? 0) }
        return max(0, n - Self.maxRows)
    }

    var busy: Bool {
        if inNodeList { return scanning }
        return (trail.last.map { [$0] } ?? current?.paths ?? []).contains { loading.contains($0) }
    }

    /// Algum du ou find em curso: o Mover espera, para não apagar o que está sendo medido.
    var measuring: Bool { scanning || !loading.isEmpty }

    private var scanning: Bool { if case .measuring = nodeScan { return true }; return nodeScan == .finding }

    var errorText: String? {
        if inNodeList { return nodeScan == .failed ? "Não deu para procurar as node_modules (prazo ou permissão)." : nil }
        let paths = trail.last.map { [$0] } ?? current?.paths ?? []
        return paths.contains { failed.contains($0) } ? "Parte desta pasta não foi medida (prazo ou permissão). Clique em recarregar." : nil
    }

    /// Projeto de uma node_modules: o caminho depois de ~/Projetos, sem o "/node_modules" do fim.
    private func nodeTitle(_ path: String) -> String {
        let prefix = home + "/Projetos/"
        let rel = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        return rel.hasSuffix("/node_modules") ? String(rel.dropLast("/node_modules".count)) : rel
    }

    func row(id: String?) -> DiskRow? { rows.first { $0.id == id } }

    /// A regra da Lixeira (com leitura de disco) roda aqui, uma vez por escolha, e não a cada desenho.
    func select(_ id: String?) {
        selection = id
        selectedCanTrash = row(id: id)?.path.map { DiskRules.canTrashItem($0, home: home) } ?? false
    }

    var series: DiskRules.Series? { DiskRules.series(history: history, category: categoryID, now: Date()) }

    // MARK: navegar

    func choose(_ id: String) {
        categoryID = id; trail = []; select(nil); notice = nil
        loadCurrent()
    }

    func enter(_ row: DiskRow) {
        guard row.enterable else { return }
        trail.append(row.virtual ? Self.nodeKey : row.path ?? ""); select(nil)
        loadCurrent()
    }

    /// Índice 0 = a categoria; os seguintes = as pastas da trilha.
    func back(to index: Int) {
        guard index < trail.count else { return }
        trail = Array(trail.prefix(index)); select(nil)
        loadCurrent()
    }

    /// "Atualizar": mede de novo o que está à vista, sem olhar a idade nem a bateria.
    func reload() {
        guard !moving, !updating else { return }
        let paths = trail.last.map { [$0] } ?? current?.paths ?? []
        if inNodeList || (trail.isEmpty && current?.id == "projects") { nodeScan = .idle; nodeModules = []; skipNodeCache = true }
        paths.forEach { cache[$0] = nil; stale.remove($0); failed.remove($0); noSeed.insert($0); fromSeed.remove($0) }
        loadCurrent()
    }

    private func loadCurrent() {
        if inNodeList { startNodeScan(); return }
        if let p = trail.last { load(p); return }
        guard let c = current else { return }
        c.paths.forEach(load)
        if c.id == "projects" { startNodeScan() }
    }

    // MARK: medir

    private func deadline(_ path: String) -> TimeInterval { path == home + "/Projetos" ? 180 : DiskModel.duDeadline }

    private func load(_ path: String) {
        if cache[path] != nil, stale.contains(path) { refresh(path); return }
        guard cache[path] == nil, !loading.contains(path), !demo, model.cacheLoaded else { return }
        loading.insert(path); failed.remove(path)
        let wait = deadline(path)
        // Do mais novo para o mais velho: a medida guardada da pasta, a leitura do DiskModel (raízes das categorias), um du novo.
        let fresh = !noSeed.contains(path)
        let saved = fresh ? model.cache.folders[path] : nil
        // Raiz sem medida boa (parcial) não vale como semente, nem com lista vazia.
        let rootBad = model.categories.first { $0.paths.contains(path) }?.unmeasured ?? false
        let seeded = fresh ? model.children[path].flatMap { $0.isEmpty && rootBad ? nil : (DiskRules.Reading(), $0) } : nil
        let seedAt = model.measuredAt ?? .distantPast
        if let saved, seeded == nil || saved.at >= seedAt {
            folderQueue.async { [weak self] in
                let alive = saved.entries.filter { FileManager.default.fileExists(atPath: $0.path) }   // pasta apagada desde a medida sai da lista
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading.remove(path)
                    self.folderAt[path] = saved.at; self.cache[path] = alive
                    if self.model.autoMeasureAllowed(saved.at) { self.refresh(path) }
                }
            }
            return
        }
        folderQueue.async { [weak self] in
            guard let self else { return }
            let (r, children) = seeded ?? self.runner.du(path, deadline: wait)
            let entries = r.good ? children.filter { $0.bytes > 0 }.map { Self.entry($0.path, $0.bytes) } + Self.looseFiles(path) : []
            DispatchQueue.main.async {
                self.loading.remove(path)
                if r.good {
                    self.stale.remove(path)
                    if seeded != nil { self.fromSeed.insert(path); self.folderAt[path] = seedAt; self.cache[path] = entries.sorted { $0.bytes > $1.bytes } }
                    else { self.store(path, entries); self.model.rootMeasured(path, r.bytes, children) }
                } else if !self.runner.isStopped { self.failed.insert(path) }
            }
        }
    }

    /// Guarda uma medida nova de pasta: na tela e no arquivo.
    private func store(_ path: String, _ entries: [DiskEntry]) {
        let now = Date(), sorted = entries.sorted { $0.bytes > $1.bytes }
        folderAt[path] = now
        model.updateCache { $0.setFolder(path, sorted, at: now) }
        cache[path] = sorted
    }

    /// Arquivos soltos da pasta (o `du -d 1` só lista as subpastas): tamanho em disco pelo stat.
    /// Mede de novo sem esconder a lista: o cache velho continua à vista até a medida nova chegar. Não conta como `measuring`.
    private func refresh(_ path: String) {
        guard !refreshing.contains(path), !demo else { return }
        refreshing.insert(path)
        let started = staleGen[path] ?? 0
        let wait = deadline(path)
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let (r, children) = self.runner.du(path, deadline: wait)
            let entries = r.good ? children.filter { $0.bytes > 0 }.map { Self.entry($0.path, $0.bytes) } + Self.looseFiles(path) : []
            DispatchQueue.main.async {
                self.refreshing.remove(path)
                guard r.good, !self.runner.isStopped else { return }
                switch DiskRules.refreshAction(started: started, current: self.staleGen[path] ?? 0) {
                case .store: self.stale.remove(path); self.store(path, entries); self.model.rootMeasured(path, r.bytes, children)
                case .remeasure: self.refresh(path)
                }
            }
        }
    }

    private static func looseFiles(_ dir: String) -> [DiskEntry] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name in
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR, st.st_blocks > 0 else { return nil }
            return DiskEntry(path: path, bytes: UInt64(st.st_blocks) * 512, modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), isDir: false)
        }
    }

    private static func entry(_ path: String, _ bytes: UInt64) -> DiskEntry {
        var st = stat()
        guard lstat(path, &st) == 0 else { return DiskEntry(path: path, bytes: bytes, modified: nil, isDir: false) }
        let t = st.st_mtimespec
        return DiskEntry(path: path, bytes: bytes, modified: Date(timeIntervalSince1970: TimeInterval(t.tv_sec)), isDir: (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// Mostra a lista guardada. Se ela tem mais de 24 h (e a bateria deixa) ou não existe: `find` com prazo e depois o `du`
    /// de cada node_modules, devagar e uma por vez. Sem lista à vista a soma cresce na tela; com lista, ela troca no fim.
    private func startNodeScan() {
        guard nodeScan == .idle, !demo, model.cacheLoaded else { return }
        nodeScan = .finding; nodeModules = []
        scanGeneration += 1
        let gen = scanGeneration
        let root = home + "/Projetos", wait = DiskModel.duDeadline
        let saved = skipNodeCache ? nil : model.cache.nodeModules
        skipNodeCache = false
        nodeQueue.async { [weak self] in
            guard let self else { return }
            var keepOld = false
            if let saved {
                let alive = saved.entries.filter { FileManager.default.fileExists(atPath: $0.path) }
                let again = self.model.autoMeasureAllowed(saved.at)
                DispatchQueue.main.async {
                    guard gen == self.scanGeneration else { return }
                    self.nodeAt = saved.at; self.nodeModules = alive
                    if !again { self.nodeScan = .done }
                }
                if !again { return }
                keepOld = true
            }
            let found = self.runner.run("/usr/bin/find", [root, "-maxdepth", "5", "-name", "node_modules", "-type", "d", "-prune", "-print0"], deadline: wait)
            if found.timedOut {
                DispatchQueue.main.async { if !self.runner.isStopped, gen == self.scanGeneration { self.nodeScan = .failed } }
                return
            }
            let paths = found.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            DispatchQueue.main.async { if gen == self.scanGeneration { self.nodeScan = .measuring(done: 0, of: paths.count) } }
            var all: [DiskEntry] = []
            for (i, path) in paths.enumerated() {
                let (r, _) = self.runner.du(path, deadline: wait)
                if self.runner.isStopped { return }
                let e = r.good && FileManager.default.fileExists(atPath: path) ? Self.entry(path, r.bytes) : nil
                if let e { all.append(e) }
                DispatchQueue.main.async {
                    guard gen == self.scanGeneration else { return }
                    if let e, !keepOld { self.nodeModules.append(e) }
                    self.nodeScan = .measuring(done: i + 1, of: paths.count)
                }
            }
            let now = Date(), result = all
            DispatchQueue.main.async {
                guard gen == self.scanGeneration else { return }
                self.nodeAt = now; self.nodeModules = result; self.nodeScan = .done
                self.model.updateCache { $0.nodeModules = DiskCache.Folder(at: now, entries: result) }
            }
        }
    }

    // MARK: Lixeira

    /// Move para a Lixeira (nunca apaga). A regra é conferida de novo aqui, na fila, na hora de mover.
    /// A medida de fundo (`refresh`) não bloqueia o Mover; o du ou o find de uma escolha do usuário bloqueia.
    func trash(_ path: String, bytes: UInt64) {
        let name = (path as NSString).lastPathComponent
        guard !moving else { return }
        guard !measuring, !model.measuring, !model.moving else { notice = "Espere a medida terminar para mover \(name)."; return }
        guard DiskRules.canTrashItem(path, home: home) else { notice = "A regra não deixa mover \(name) para a Lixeira."; return }
        moving = true; model.beginMove()
        let disk = model   // forte: o endMove roda mesmo se a janela fechar no meio do Mover
        folderQueue.async { [weak self] in
            var failure: String?
            if !DiskRules.canTrashItem(path, home: NSHomeDirectory()) { failure = "A regra não deixa mover \(name) para a Lixeira." }
            else {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
                catch { failure = "Não consegui mover \(name): \(error.localizedDescription)" }
            }
            DispatchQueue.main.async {
                disk.endMove()
                if failure == nil, self == nil { disk.removed([(path, bytes)]) }
                guard let self else { return }
                self.moving = false; self.select(nil)
                if let failure { self.notice = failure; return }
                self.notice = "\(DiskRules.size(bytes)) na Lixeira. Esvazie a Lixeira para liberar o espaço."
                self.forget(path, bytes: bytes)
                self.loadCurrent()
                self.model.removed([(path, bytes)])
            }
        }
    }

    /// Tira só a linha movida e subtrai os bytes dela das pastas acima. A lista fica à vista; as pastas acima são medidas de novo em segundo plano.
    private func forget(_ path: String, bytes: UInt64) {
        var next = cache
        for (key, list) in cache {
            if key == path || key.hasPrefix(path + "/") { next[key] = nil; staleGen[key, default: 0] += 1; continue }
            guard list.contains(where: { $0.path == path || path.hasPrefix($0.path + "/") }) else { continue }
            next[key] = list.filter { $0.path != path }.map { e in
                path.hasPrefix(e.path + "/") ? DiskEntry(path: e.path, bytes: e.bytes > bytes ? e.bytes - bytes : 0, modified: e.modified, isDir: e.isDir) : e
            }
            stale.insert(key); noSeed.insert(key); staleGen[key, default: 0] += 1
        }
        let gone = cache.keys.filter { next[$0] == nil }
        gone.forEach { folderAt[$0] = nil; fromSeed.remove($0) }
        let changed = next.filter { cache[$0.key] != $0.value }
        cache = next
        nodeModules.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        let nodes = nodeModules, nodeDate = nodeAt
        model.updateCache { c in
            gone.forEach { c.folders[$0] = nil }
            for (k, v) in changed where c.folders[k] != nil { c.folders[k] = DiskCache.Folder(at: c.folders[k]!.at, entries: v) }
            if let nodeDate { c.nodeModules = DiskCache.Folder(at: nodeDate, entries: nodes) }
        }
    }

    // MARK: demonstração

    /// ILAND_DISK_DEMO=1: números inventados, sem du, find nem arquivo de histórico.
    func loadDemo() {
        demo = true
        let gb: UInt64 = 1 << 30, mb: UInt64 = 1 << 20, day: TimeInterval = 86_400, now = Date()
        func e(_ p: String, _ b: UInt64, _ days: Double, dir: Bool = true) -> DiskEntry { DiskEntry(path: "\(home)/\(p)", bytes: b, modified: now.addingTimeInterval(-days * day), isDir: dir) }
        cache = [
            home + "/Projetos": [e("Projetos/instanalysis", 15 * gb, 3), e("Projetos/anota", 15 * gb, 1), e("Projetos/CRM-loop", 3 * gb + 200 * mb, 75),
                                 e("Projetos/Default", 2 * gb + 700 * mb, 20), e("Projetos/iLand", 2 * gb, 0), e("Projetos/tracking.mov", 1 * gb, 10, dir: false), e("Projetos/Filmes", 900 * mb, 130)],
            home + "/.cache": [e(".cache/codebase-memory-mcp", 19 * gb, 1), e(".cache/uv", 10 * gb, 2), e(".cache/codex", 4 * gb, 5)],
            home + "/.npm": [e(".npm/_cacache", 2 * gb, 1)],
            home + "/Library/Caches": [e("Library/Caches/Google", 6 * gb, 1), e("Library/Caches/Homebrew", 3 * gb, 9)],
            home + "/Library/Application Support/Claude": [e("Library/Application Support/Claude/vm_bundles", 7 * gb, 4)],
            home + "/.claude": [e(".claude/projects", 4 * gb, 0), e(".claude/todos", 500 * mb, 3)],
            home + "/Movies": [e("Movies/Gravacoes", 12 * gb, 40), e("Movies/clip.mov", 4 * gb, 200, dir: false)],
            home + "/Downloads": [e("Downloads/instalador.dmg", 2 * gb, 90, dir: false), e("Downloads/fotos", 900 * mb, 15)],
            home + "/Documents": [e("Documents/Contratos", 2 * gb, 120)],
            home + "/.Trash": [e(".Trash/velho", gb, 70)],
        ]
        nodeModules = (0..<12).map { i in e("Projetos/\(["instanalysis", "anota", "CRM-loop", "Default", "iLand", "site", "api", "painel", "bot", "docs", "loja", "admin"][i])/node_modules", UInt64(900 - i * 55) * mb, i < 7 ? 100 : 5) }
        nodeScan = .done
        history = (0..<31).map { d in
            let total = 150 * gb + UInt64(Double(30 - d) * 0.3 * Double(gb)) + (d % 3 == 0 ? gb / 2 : 0)
            return DiskRules.Snapshot(day: DiskRules.dayKey(now.addingTimeInterval(-Double(d) * day)), sizes: ["projects": total * 40 / 100, "tools": total * 30 / 100, "movies": total * 10 / 100, "system": total * 10 / 100, "claude": total * 10 / 100])
        }
    }
}
