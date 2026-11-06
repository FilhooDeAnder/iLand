import Foundation
import AppKit
import IOKit.ps

enum DiskAction { case clean, review }

struct DiskCategory: Identifiable {
    let id: String
    let title: String
    let action: DiskAction
    let open: String        // pasta que "Revisar" abre no Finder
    let paths: [String]     // pastas medidas (a janela Disco lista os filhos delas)
    var bytes: UInt64
    var unmeasured = false   // alguma pasta estourou o prazo ou falhou: o tamanho é parcial
}

struct DiskItem: Identifiable, Codable, Equatable {
    let path: String
    let bytes: UInt64
    var id: String { path }
}

/// Um item medido: pasta ou arquivo, com a data de modificação da própria pasta (sem ler a árvore).
struct DiskEntry: Identifiable, Equatable, Codable {
    let path: String
    let bytes: UInt64
    let modified: Date?
    let isDir: Bool
    var id: String { path }
}

/// O que as medidas guardam em ~/Library/Application Support/iLand/disk-cache.json.
/// Arquivo corrompido ou de outra versão é ignorado (volta ao vazio e mede de novo).
struct DiskCache: Codable, Equatable {
    static let version = 1
    static let maxFolders = 200   // loop-debt: acima disso sai a pasta medida há mais tempo; cada pasta guarda todos os filhos

    struct Cat: Codable, Equatable { var id: String; var bytes: UInt64; var unmeasured: Bool }
    struct Folder: Codable, Equatable { var at: Date; var entries: [DiskEntry] }

    var version = DiskCache.version
    var categoriesAt: Date?
    var categories: [Cat] = []
    var children: [String: [DiskItem]] = [:]   // filhos das raízes das categorias (a janela reaproveita)
    var folders: [String: Folder] = [:]        // pastas medidas pela janela, por caminho
    var stale: Bool?                           // um Mover não conseguiu medir de novo: a próxima abertura mede tudo
    var roots: [String: UInt64]?               // total de cada raiz das categorias (nil em arquivo antigo)
    var nodeModules: Folder?                   // a varredura de node_modules em ~/Projetos

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLand/disk-cache.json")
    }

    static func decode(_ data: Data) -> DiskCache? {
        guard let c = try? JSONDecoder().decode(DiskCache.self, from: data), c.version == version else { return nil }
        return c
    }

    static func load(from url: URL) -> DiskCache? { (try? Data(contentsOf: url)).flatMap(decode) }

    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    mutating func setFolder(_ path: String, _ entries: [DiskEntry], at: Date) {
        folders[path] = Folder(at: at, entries: entries)
        for (p, _) in folders.sorted(by: { $0.value.at < $1.value.at }).prefix(max(0, folders.count - Self.maxFolders)) { folders[p] = nil }
    }

    /// Tira o que não existe mais (fileExists é barato). Roda fora da main.
    func pruned(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> DiskCache {
        var c = self
        c.children = children.mapValues { $0.filter { exists($0.path) } }
        c.folders = folders.mapValues { Folder(at: $0.at, entries: $0.entries.filter { exists($0.path) }) }
        c.nodeModules = nodeModules.map { Folder(at: $0.at, entries: $0.entries.filter { exists($0.path) }) }
        return c
    }
}

/// Mede as pastas que mais ocupam disco (em fila de fundo), guarda a foto diária e move caches escolhidos para a Lixeira.
/// A regra do que pode ir para a Lixeira é DiskRules.canTrash, conferida de novo na hora de mover.
final class DiskModel: ObservableObject {
    @Published private(set) var categories: [DiskCategory] = []
    @Published private(set) var items: [DiskItem] = []        // subpastas das categorias "Limpar", maiores primeiro
    @Published private(set) var growth: DiskRules.Growth?
    @Published private(set) var measuring = false
    @Published private(set) var measured = false
    @Published var confirming = false
    @Published var selected = Set<String>()
    @Published private(set) var moving = false
    @Published private(set) var result: String?

    @Published private(set) var cacheLoaded = false
    private(set) var cache = DiskCache()   // só na main; a janela grava as pastas por updateCache
    private(set) var measuredAt: Date?
    private var roots: [String: UInt64] = [:]   // total de cada raiz medida
    private var movers = 0                       // Movers em curso (página e janela): a medida completa espera
    private var rootGen: [String: Int] = [:]     // cada Mover ou medida da raiz aumenta: resultado de fundo mais velho não vale
    private var needsMeasure = false             // a correção em fundo falhou duas vezes
    private var movedDuringMeasure: [(path: String, bytes: UInt64)] = []
    private(set) var children: [String: [DiskItem]] = [:]   // filhos diretos das pastas bem medidas (a janela Disco reaproveita)
    private let home = NSHomeDirectory()
    static let duDeadline: TimeInterval = 60   // por pasta (~/Projetos tem prazo maior: Spec.deadline)
    private let runner = DuRunner()
    private let queue = DispatchQueue(label: "br.com.loop4.iland.disk", qos: .utility)
    private let writer = DispatchQueue(label: "br.com.loop4.iland.disk.cache", qos: .utility)
    private let cacheURL: URL
    private var demo = false
    private var wantAuto = false   // measureIfStale chegou antes de o arquivo carregar
    static let minItemBytes: UInt64 = 10 << 20   // subpastas menores que 10 MB só enchem a lista

    private struct Spec { let id, title: String; let action: DiskAction; let open: String; let paths: [String]; var deadline = DiskModel.duDeadline }
    private var specs: [Spec] {
        let h = home
        return [
            Spec(id: "tools", title: "Caches de ferramentas", action: .clean, open: "\(h)/.cache", paths: ["\(h)/.cache", "\(h)/.npm"]),
            Spec(id: "system", title: "Caches do sistema", action: .clean, open: "\(h)/Library/Caches", paths: ["\(h)/Library/Caches"]),
            Spec(id: "projects", title: "Projetos", action: .review, open: "\(h)/Projetos", paths: ["\(h)/Projetos"], deadline: 180),
            Spec(id: "claude", title: "Claude", action: .review, open: "\(h)/Library/Application Support/Claude",
                 paths: ["\(h)/Library/Application Support/Claude", "\(h)/.claude"]),
            Spec(id: "movies", title: "Filmes", action: .review, open: "\(h)/Movies", paths: ["\(h)/Movies"]),
            Spec(id: "downloads", title: "Downloads", action: .review, open: "\(h)/Downloads", paths: ["\(h)/Downloads"]),
            Spec(id: "documents", title: "Documentos", action: .review, open: "\(h)/Documents", paths: ["\(h)/Documents"]),
            Spec(id: "trash", title: "Lixeira", action: .review, open: "\(h)/.Trash", paths: ["\(h)/.Trash"]),
        ]
    }

    init(cacheURL: URL = DiskCache.defaultURL) {
        self.cacheURL = cacheURL
        queue.async { [weak self] in
            let c = (DiskCache.load(from: cacheURL) ?? DiskCache()).pruned()
            let h = Self.readHistory()
            DispatchQueue.main.async { self?.apply(c, history: h) }
        }
    }

    /// Mostra o que estava guardado, sem medir.
    private func apply(_ c: DiskCache, history: [DiskRules.Snapshot]) {
        guard !demo else { return }
        cache = c
        if let at = c.categoriesAt, !c.categories.isEmpty {
            children = c.children
            roots = c.roots ?? [:]
            needsMeasure = c.stale == true
            categories = specs.map { s in
                let saved = c.categories.first { $0.id == s.id }
                return DiskCategory(id: s.id, title: s.title, action: s.action, open: s.open, paths: s.paths, bytes: saved?.bytes ?? 0, unmeasured: saved?.unmeasured ?? true)
            }
            items = cleanItems(c.children)
            measuredAt = at; measured = true
            let sizes = Dictionary(uniqueKeysWithValues: categories.filter { !$0.unmeasured }.map { ($0.id, $0.bytes) })
            growth = DiskRules.growth(current: sizes, history: history, now: Date())
        }
        cacheLoaded = true
        if wantAuto { wantAuto = false; measureIfStale() }
    }

    /// Grava no cache (main) e salva em fundo, atomicamente, em ordem.
    func updateCache(_ change: (inout DiskCache) -> Void) {
        change(&cache)
        guard !demo else { return }
        let snap = cache, url = cacheURL
        writer.async { snap.save(to: url) }
    }

    private func cleanItems(_ kids: [String: [DiskItem]]) -> [DiskItem] {
        let home = home
        return specs.filter { $0.action == .clean }.flatMap { $0.paths.flatMap { kids[$0] ?? [] } }
            .filter { $0.bytes >= Self.minItemBytes && DiskRules.canTrash($0.path, home: home) }.sorted { $0.bytes > $1.bytes }
    }

    /// Energia e bateria, como o SystemMetrics lê (IOPS). Sem fonte de energia (desktop): na tomada.
    static func powerState() -> (onPower: Bool, battery: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (true, nil) }
        var state = (onPower: true, battery: Int?.none)
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any], let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            state = ((d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue, cap)
        }
        return state
    }

    /// A regra de idade e bateria para uma medida guardada de `at` (usada pela janela, por pasta).
    func autoMeasureAllowed(_ at: Date?, now: Date = Date()) -> Bool {
        let p = Self.powerState()
        return DiskRules.shouldAutoMeasure(measuredAt: at, now: now, onPower: p.onPower, battery: p.battery)
    }

    /// As 5 maiores, em ordem de tamanho.
    var top: [DiskCategory] { Array(categories.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(5)) }
    var cleanable: Bool { !items.isEmpty }
    var selectedBytes: UInt64 { items.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.bytes } }

    func shortPath(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

    // MARK: medir

    /// Mede ao abrir a página ou a janela, se a medida guardada tem mais de 24 h e a bateria deixa.
    func measureIfStale(now: Date = Date()) {
        guard cacheLoaded, !moving else { wantAuto = true; return }   // volta a tentar no fim do carregamento ou do Mover
        if autoMeasureAllowed(needsMeasure ? nil : measuredAt, now: now) { measure() }
    }

    /// A janela e a página marcam o Mover aqui: `measure()` não roda enquanto ele não termina.
    func beginMove() { movers += 1; moving = true }
    func endMove() {
        movers = max(0, movers - 1); moving = movers > 0
        if !moving, wantAuto { wantAuto = false; measureIfStale() }
    }

    func measure() {
        guard !measuring, !moving else { return }
        measuring = true
        movedDuringMeasure = []
        let specs = specs
        queue.async { [weak self] in
            var cats: [DiskCategory] = [], kids: [String: [DiskItem]] = [:], rootBytes: [String: UInt64] = [:]
            for s in specs {
                var total: UInt64 = 0, bad = false
                for path in s.paths {
                    guard let self else { return }
                    let (r, children) = self.runner.du(path, deadline: s.deadline)
                    total += r.bytes
                    if !r.good { bad = true } else { kids[path] = children; rootBytes[path] = r.bytes }
                }
                cats.append(DiskCategory(id: s.id, title: s.title, action: s.action, open: s.open, paths: s.paths, bytes: total, unmeasured: bad))
            }
            DispatchQueue.main.async { self?.finish(cats, kids, rootBytes) }
        }
    }

    private func finish(_ cats: [DiskCategory], _ kids: [String: [DiskItem]], _ rootBytes: [String: UInt64]) {
        let now = Date()
        var kids = kids, cats = cats, rootBytes = rootBytes
        // Um item movido durante a medida não volta: sai da lista e, se estava nela, dos totais.
        for g in movedDuringMeasure {
            guard let root = kids.keys.first(where: { g.path.hasPrefix($0 + "/") }) else { continue }
            if let hit = kids[root]?.first(where: { $0.path == g.path }) {
                cats = cats.map { c in var c = c; if c.paths.contains(root) { c.bytes = DiskRules.shrink(c.bytes, by: hit.bytes) }; return c }
                rootBytes[root] = rootBytes[root].map { DiskRules.shrink($0, by: hit.bytes) }
            }
            kids[root] = DiskRules.removing(path: g.path, bytes: g.bytes, from: kids[root] ?? [])
        }
        movedDuringMeasure = []
        needsMeasure = false
        children = kids; roots = rootBytes
        categories = cats
        items = cleanItems(kids)
        selected = selected.intersection(items.map(\.path))
        measuring = false; measured = true; measuredAt = now
        updateCache {
            $0.categoriesAt = now; $0.children = kids; $0.roots = rootBytes; $0.stale = nil
            $0.categories = cats.map { DiskCache.Cat(id: $0.id, bytes: $0.bytes, unmeasured: $0.unmeasured) }
        }
        // Só as categorias bem medidas entram na foto do dia (e no "cresceu"): uma pasta lenta não bloqueia as outras.
        // Uma medida boa mais tarde no mesmo dia completa a foto com o que faltava.
        let sizes = Dictionary(uniqueKeysWithValues: cats.filter { !$0.unmeasured }.map { ($0.id, $0.bytes) })
        guard !sizes.isEmpty else { return }
        let history = DiskRules.record(Self.readHistory(), sizes: sizes, now: Date())
        Self.writeHistory(history)
        growth = DiskRules.growth(current: sizes, history: history, now: Date())
    }

    /// Depois de mover para a Lixeira: subtrai os bytes das categorias e das listas, grava, e mede de novo em fundo só a pasta afetada
    /// (a raiz, ou o filho direto da raiz que contém o item). Não mexe na foto diária: ela só vem de uma medida completa.
    func removed(_ gone: [(path: String, bytes: UInt64)]) {
        var targets: [(path: String, root: String)] = []
        let allRoots = specs.flatMap(\.paths)
        if measuring { movedDuringMeasure += gone }
        for g in gone {
            guard let root = allRoots.first(where: { g.path.hasPrefix($0 + "/") }) else { continue }
            rootGen[root, default: 0] += 1
            categories = categories.map { c in
                var c = c
                if c.paths.contains(root) { c.bytes = DiskRules.shrink(c.bytes, by: g.bytes) }
                return c
            }
            if let list = children[root] { children[root] = DiskRules.removing(path: g.path, bytes: g.bytes, from: list) }   // raiz sem lista medida: não inventa uma vazia
            roots[root].map { roots[root] = DiskRules.shrink($0, by: g.bytes) }
            let parent = (g.path as NSString).deletingLastPathComponent
            targets.append((parent == root || (parent as NSString).deletingLastPathComponent == root ? parent : root + "/" + g.path.dropFirst(root.count + 1).prefix { $0 != "/" }, root))
        }
        items = cleanItems(children)
        selected = selected.intersection(items.map(\.path))
        saveSizes()
        // loop-debt: dois Movers seguidos na mesma raiz: só o último mede (o primeiro fica com a subtração). Upgrade: juntar os alvos pendentes por raiz.
        for t in Set(targets.map(\.path)) { if let root = targets.first(where: { $0.path == t })?.root { remeasure(t, root: root, gen: rootGen[root] ?? 0, attempt: 0) } }
    }

    /// `du` em fundo do alvo. Falhou: tenta de novo uma vez em 5 s. Falhou de novo: a próxima abertura mede tudo.
    private func remeasure(_ target: String, root: String, gen: Int, attempt: Int) {
        let wait = specs.first { $0.paths.contains(root) }?.deadline ?? Self.duDeadline
        queue.async { [weak self] in
            guard let self else { return }
            let (r, kids) = self.runner.du(target, deadline: wait)
            if self.runner.isStopped { return }
            DispatchQueue.main.async {
                guard self.rootGen[root] == gen else { return }   // um Mover ou uma medida mais nova da raiz já passou por aqui
                if r.good { self.applyRemeasured(target, root: root, r.bytes, kids) }
                else if attempt == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if self.rootGen[root] == gen { self.remeasure(target, root: root, gen: gen, attempt: 1) } } }
                else { self.needsMeasure = true; self.updateCache { $0.stale = true } }
            }
        }
    }

    /// A janela mediu uma raiz de categoria (Atualizar): o total da categoria e o cache acompanham.
    func rootMeasured(_ root: String, _ bytes: UInt64, _ kids: [DiskItem]) {
        guard specs.contains(where: { $0.paths.contains(root) }) else { return }
        rootGen[root, default: 0] += 1
        applyRemeasured(root, root: root, bytes, kids)
    }

    private func applyRemeasured(_ target: String, root: String, _ bytes: UInt64, _ kids: [DiskItem]) {
        var delta: Int64
        if target == root {
            let old = roots[root]
            children[root] = kids; roots[root] = bytes
            guard let old else { items = cleanItems(children); saveSizes(); return }   // sem o total antigo da raiz não há como corrigir a categoria
            delta = Int64(bytes) - Int64(old)
        } else {
            guard var list = children[root], let i = list.firstIndex(where: { $0.path == target }) else { return }
            delta = Int64(bytes) - Int64(list[i].bytes)
            list[i] = DiskItem(path: target, bytes: bytes)
            children[root] = list
        }
        if target != root { roots[root].map { roots[root] = DiskRules.adjusted($0, by: delta) } }
        categories = categories.map { c in
            var c = c
            if c.paths.contains(root) { c.bytes = DiskRules.adjusted(c.bytes, by: delta) }
            return c
        }
        items = cleanItems(children)
        selected = selected.intersection(items.map(\.path))
        saveSizes()
    }

    private func saveSizes() {
        let cats = categories, kids = children, rootBytes = roots
        updateCache {
            $0.categories = cats.map { DiskCache.Cat(id: $0.id, bytes: $0.bytes, unmeasured: $0.unmeasured) }
            $0.children = kids; $0.roots = rootBytes
        }
    }

    /// Ao sair do app: termina o du que ainda roda e impede novos.
    func stop() { runner.stop() }

    // MARK: foto diária

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLand/disk-history.json")
    }

    static func readHistory() -> [DiskRules.Snapshot] {
        (try? JSONDecoder().decode([DiskRules.Snapshot].self, from: Data(contentsOf: historyURL))) ?? []
    }

    private static func writeHistory(_ h: [DiskRules.Snapshot]) {
        let dir = historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(h) { try? data.write(to: historyURL, options: .atomic) }
    }

    // MARK: ações

    func startConfirm() { selected = []; result = nil; confirming = true }
    func cancel() { confirming = false; selected = [] }

    func toggle(_ path: String) { if !selected.insert(path).inserted { selected.remove(path) } }

    /// Move os marcados para a Lixeira (nunca apaga). O que a regra recusa fica de fora e conta como falha.
    func moveSelected() {
        guard !moving, !measuring, !selected.isEmpty else { return }
        beginMove()
        let chosen = items.filter { selected.contains($0.path) }, home = home
        queue.async { [weak self] in
            var moved: UInt64 = 0, failed = 0, movedItems: [(path: String, bytes: UInt64)] = []
            for item in chosen {
                guard DiskRules.canTrash(item.path, home: home),
                      (try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)) != nil else { failed += 1; continue }
                moved += item.bytes; movedItems.append((item.path, item.bytes))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.endMove(); self.confirming = false; self.selected = []
                self.result = (moved > 0 ? "\(DiskRules.size(moved)) na Lixeira. Esvazie a Lixeira para liberar o espaço." : "Nada foi movido.")
                    + (failed > 0 ? " \(failed) não saíram do lugar." : "")
                self.removed(movedItems)
            }
        }
    }

    /// Depuração (ILAND_DISK_DEMO=1): números inventados, sem medir nada nem escrever o histórico.
    func loadDemo() {
        demo = true
        let gb: UInt64 = 1 << 30
        let sizes: [(String, UInt64)] = [("projects", 52 * gb), ("tools", 37 * gb), ("movies", 17 * gb), ("system", 15 * gb), ("claude", 12 * gb),
                                         ("downloads", 3 * gb), ("documents", 2 * gb), ("trash", gb)]
        categories = specs.map { s in DiskCategory(id: s.id, title: s.title, action: s.action, open: s.open, paths: s.paths, bytes: sizes.first { $0.0 == s.id }?.1 ?? 0) }
        items = [("\(home)/.cache/codebase-memory-mcp", 19 * gb), ("Library/Caches/Google", 6 * gb), (".cache/uv", 10 * gb), (".cache/codex", 4 * gb), ("Library/Caches/Homebrew", 3 * gb), (".npm/_cacache", 2 * gb)]
            .map { DiskItem(path: $0.0.hasPrefix("/") ? $0.0 : "\(home)/\($0.0)", bytes: $0.1) }.sorted { $0.bytes > $1.bytes }
        growth = DiskRules.Growth(items: [("tools", 3 * gb + gb / 10), ("claude", gb * 8 / 10)], days: 7)
        measured = true; measuredAt = Date(); cacheLoaded = true
        if ProcessInfo.processInfo.environment["ILAND_DISK_CONFIRM"] != nil { confirming = true; selected = Set(items.prefix(2).map(\.path)) }
    }
}

/// Roda `du` (e `find`) com prazo e leitura de saída num jeito só. Cada dono tem o seu: `stop()` termina o que roda e impede novos.
final class DuRunner {
    static let logRuns = ProcessInfo.processInfo.environment["ILAND_DISK_LOG"] != nil   // depuração: uma linha por du/find lançado
    private let lock = NSLock()
    private var running: [Process] = []
    private var stopped = false

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Estourou o prazo: termina o processo e devolve `timedOut`. Não iniciou ou já parado: também `timedOut` e sem dados.
    func run(_ exe: String, _ args: [String], deadline: TimeInterval) -> (data: Data, status: Int32, timedOut: Bool) {
        if Self.logRuns { FileHandle.standardError.write(Data("disk-run \(exe) \(args.joined(separator: " "))\n".utf8)) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), exited = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0)
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in exited.signal() }
        lock.lock()
        if stopped { lock.unlock(); return (Data(), 0, true) }
        guard (try? p.run()) != nil else { lock.unlock(); return (Data(), 0, true) }
        running.append(p)
        lock.unlock()
        // A saída é lida de um jeito só: readDataToEndOfFile numa fila à parte, que termina quando o processo sai e fecha o pipe.
        var data = Data()
        DispatchQueue.global(qos: .utility).async { data = out.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        var timedOut = false
        if exited.wait(timeout: .now() + deadline) == .timedOut {
            p.terminate()
            _ = exited.wait(timeout: .now() + 2)   // preso em disco lento pode nem sair: não esperamos mais
            timedOut = true
        }
        lock.lock(); running.removeAll { $0 === p }; lock.unlock()
        if timedOut || read.wait(timeout: .now() + 5) == .timedOut { return (Data(), 0, true) }
        return (data, p.terminationStatus, false)
    }

    /// `du -k -d 1`: o tamanho da própria pasta e o de cada filho direto (o du do macOS não mistura -a com -d: arquivos soltos não saem aqui).
    /// Falha de permissão em parte dos arquivos faz o du sair com erro mas ainda imprimir o resto: usa o que veio.
    func du(_ path: String, deadline: TimeInterval) -> (DiskRules.Reading, [DiskItem]) {
        var r = DiskRules.Reading()
        r.exists = FileManager.default.fileExists(atPath: path)
        guard r.exists else { return (r, []) }
        r.found = false
        let res = run("/usr/bin/du", ["-k", "-d", "1", path], deadline: deadline)
        if res.timedOut { r.timedOut = true; return (r, []) }
        r.status = res.status
        var children: [DiskItem] = []
        for line in String(decoding: res.data, as: UTF8.self).split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = UInt64(line[..<tab]) else { continue }
            let name = String(line[line.index(after: tab)...])
            if name == path { r.bytes = kb * 1024; r.found = true } else { children.append(DiskItem(path: name, bytes: kb * 1024)) }
        }
        return (r, children)
    }

    func stop() {
        lock.lock(); stopped = true; running.forEach { $0.terminate() }; lock.unlock()
    }
}
