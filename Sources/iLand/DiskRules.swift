import Foundation

/// Regras puras da página Disco: o que pode ir para a Lixeira, a foto diária dos tamanhos e o cálculo do "cresceu".
enum DiskRules {
    /// Só filho DIRETO destas pastas pode ir para a Lixeira pelo iLand.
    static func cleanRoots(home: String) -> [String] { ["\(home)/.cache", "\(home)/.npm", "\(home)/Library/Caches"] }

    /// Recusa a própria raiz, "..", caminho relativo e tudo fora das raízes. O link simbólico é resolvido antes:
    /// um filho que aponta para fora das raízes não passa.
    static func canTrash(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains("..") else { return false }
        let parent = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().path
        return cleanRoots(home: home).contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == parent }
    }

    /// Pastas que o build ou o gerenciador de pacotes cria de novo. Só estas vão para a Lixeira dentro de ~/Projetos.
    static let recreatable: Set<String> = ["node_modules", ".venv", "venv", "DerivedData", ".next", "dist", "build", "target", "__pycache__"]

    /// Regra da janela Disco: o que `canTrash` aceita, ou uma pasta recriável dentro de um projeto de ~/Projetos.
    /// Recusa ~/Projetos, o projeto inteiro (filho direto), ".." e tudo dentro de ~/.claude e de Application Support/Claude.
    /// O link simbólico é resolvido antes de todas as checagens.
    static func canTrashItem(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains("..") else { return false }
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let resolved = real(path), realHome = real(home)
        for blocked in ["\(realHome)/.claude", "\(realHome)/Library/Application Support/Claude"] where resolved == blocked || resolved.hasPrefix(blocked + "/") {
            return false
        }
        if canTrash(path, home: home) { return true }
        let projects = real("\(home)/Projetos") + "/"
        guard resolved.hasPrefix(projects) else { return false }
        let inside = resolved.dropFirst(projects.count).split(separator: "/")
        guard inside.count >= 2, let last = inside.last else { return false }
        guard recreatable.contains(String(last)) else { return false }
        // build, dist e target são nomes comuns: só valem ao lado de um arquivo de projeto.
        guard markerRequired.contains(String(last)) else { return true }
        let parent = (resolved as NSString).deletingLastPathComponent
        return projectMarkers.contains { FileManager.default.fileExists(atPath: "\(parent)/\($0)") }
    }

    static let markerRequired: Set<String> = ["build", "dist", "target"]
    static let projectMarkers = ["package.json", "Cargo.toml", "pyproject.toml", "build.gradle", "pom.xml", "Package.swift"]

    enum RefreshAction { case store, remeasure }

    /// Uma medida de fundo que começou na geração `started` só vale se o Mover não mexeu na pasta desde então.
    static func refreshAction(started: Int, current: Int) -> RefreshAction { started == current ? .store : .remeasure }

    /// Dica de uma linha (`short`) e a frase completa do detalhe (`sentence`).
    struct Hint: Equatable { var short: String; var sentence: String }

    static let staleDays = 60

    /// Dica pela regra: recriável, cache, ou sem uso há mais de 60 dias (data de modificação da própria pasta). Nada: nil.
    static func hint(path: String, modified: Date?, now: Date, home: String) -> Hint? {
        let name = (path as NSString).lastPathComponent
        switch name {
        case "node_modules": return Hint(short: "recriável: npm install", sentence: "Dependências do projeto. Voltam com npm install.")
        case ".venv", "venv": return Hint(short: "recriável: ambiente Python", sentence: "Ambiente Python do projeto. Dá para criar de novo.")
        case "DerivedData", ".next", "dist", "build", "target", "__pycache__", ".gradle":
            return Hint(short: "recriável: build", sentence: "Arquivos de build. O próximo build cria de novo.")
        default: break
        }
        if cleanRoots(home: home).contains((path as NSString).deletingLastPathComponent) {
            return Hint(short: "cache", sentence: "Cache. O programa que o criou cria de novo quando precisa.")
        }
        if let m = modified {
            let days = Int(now.timeIntervalSince(m) / 86_400)
            if days > staleDays {
                let months = days / 30
                return Hint(short: "sem uso há \(months) meses", sentence: "Sem modificação há \(months) meses. Veja se ainda precisa dela.")
            }
        }
        return nil
    }

    /// Total (`category` nil) ou uma categoria, dos últimos 30 dias. `day` = dias antes de hoje. Menos de 2 pontos: nil.
    struct Series: Equatable {
        var points: [(day: Int, bytes: UInt64)]
        var delta: Int64
        static func == (a: Series, b: Series) -> Bool { a.delta == b.delta && a.points.elementsEqual(b.points) { $0 == $1 } }
    }

    static func series(history: [Snapshot], category: String?, now: Date, calendar: Calendar = .current) -> Series? {
        let today = dayKey(now, calendar: calendar)
        let points = history.sorted { $0.day < $1.day }.compactMap { snap -> (day: Int, bytes: UInt64)? in
            let ago = days(from: snap.day, to: today, calendar: calendar)
            guard snap.day <= today, ago < 30 else { return nil }
            if let c = category { return snap.sizes[c].map { (ago, $0) } }
            return (ago, snap.sizes.values.reduce(0, +))
        }
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        return Series(points: points, delta: Int64(last.bytes) - Int64(first.bytes))
    }

    /// "+9 GB" ou "−2,1 GB" (sinal de menos de verdade).
    static func signedSize(_ delta: Int64) -> String {
        (delta < 0 ? "−" : "+") + size(UInt64(delta.magnitude))
    }

    /// Foto dos tamanhos (bytes por id de categoria) de um dia.
    struct Snapshot: Codable, Equatable {
        var day: String
        var sizes: [String: UInt64]
    }

    static let keepDays = 60

    static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Grava a foto de hoje. Se já existe, só acrescenta as categorias que faltavam (a primeira medida de cada uma vale).
    /// Guarda os últimos 60 dias.
    static func record(_ history: [Snapshot], sizes: [String: UInt64], now: Date, calendar: Calendar = .current) -> [Snapshot] {
        let today = dayKey(now, calendar: calendar)
        var h = history
        if let i = h.firstIndex(where: { $0.day == today }) { h[i].sizes.merge(sizes) { old, _ in old } }
        else { h.append(Snapshot(day: today, sizes: sizes)) }
        return Array(h.sorted { $0.day < $1.day }.suffix(keepDays))
    }

    struct Growth: Equatable {
        var items: [(id: String, bytes: UInt64)]
        var days: Int   // de que foto antiga vem a diferença
        static func == (a: Growth, b: Growth) -> Bool { a.days == b.days && a.items.elementsEqual(b.items) { $0 == $1 } }
    }

    /// Até `limit` categorias que mais cresceram desde a foto de 7 dias atrás (a mais recente que tenha 7 dias ou mais).
    /// Sem ela, usa a foto mais velha de antes de hoje. Sem nenhuma, nil ("Histórico começa hoje").
    static func growth(current: [String: UInt64], history: [Snapshot], now: Date, calendar: Calendar = .current, limit: Int = 2) -> Growth? {
        let today = dayKey(now, calendar: calendar)
        let weekAgo = dayKey(calendar.date(byAdding: .day, value: -7, to: now) ?? now, calendar: calendar)
        let past = history.filter { $0.day < today }.sorted { $0.day < $1.day }
        guard let base = past.last(where: { $0.day <= weekAgo }) ?? past.first else { return nil }
        let items = current.compactMap { id, size -> (id: String, bytes: UInt64)? in
            guard let before = base.sizes[id], size > before else { return nil }
            return (id, size - before)
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
        return Growth(items: Array(items.prefix(limit)), days: days(from: base.day, to: today, calendar: calendar))
    }

    private static func days(from a: String, to b: String, calendar: Calendar) -> Int {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let da = f.date(from: a), let db = f.date(from: b) else { return 0 }
        return calendar.dateComponents([.day], from: da, to: db).day ?? 0
    }

    /// Resultado de medir uma pasta com `du`. Medida ruim não vira foto do dia.
    struct Reading: Equatable {
        var exists = true
        var found = true          // o du imprimiu a linha da própria pasta
        var status: Int32 = 0     // saída do du (erro de permissão em parte dos arquivos dá status 1 mas ainda imprime o resto)
        var bytes: UInt64 = 0
        var timedOut = false
        /// Ruim: estourou o prazo, não imprimiu a pasta, ou deu 0 com erro numa pasta que existe.
        /// 0 sem erro é medida boa: uma Lixeira vazia mede 0.
        var good: Bool {
            guard exists else { return true }
            return !timedOut && found && !(bytes == 0 && status != 0)
        }
    }

    /// Subtrai sem passar de zero.
    static func shrink(_ total: UInt64, by bytes: UInt64) -> UInt64 { total > bytes ? total - bytes : 0 }

    /// Soma uma diferença (medida nova menos a velha) sem passar de zero.
    static func adjusted(_ total: UInt64, by delta: Int64) -> UInt64 { delta >= 0 ? total &+ UInt64(delta) : shrink(total, by: UInt64(-delta)) }

    /// Depois de mover `path` (`bytes`) para a Lixeira: tira o filho direto igual, ou subtrai do filho que contém o caminho.
    static func removing(path: String, bytes: UInt64, from kids: [DiskItem]) -> [DiskItem] {
        kids.filter { $0.path != path }.map { path.hasPrefix($0.path + "/") ? DiskItem(path: $0.path, bytes: shrink($0.bytes, by: bytes)) : $0 }
    }

    static let autoMeasureAge: TimeInterval = 86_400
    static let minBattery = 30

    /// Medida automática: só se a guardada tem mais de 24 h (ou não existe) e o Mac não está na bateria abaixo de 30%.
    /// Relógio que andou para trás (medida no futuro) conta como velha. Sem leitura de bateria (desktop): vale.
    static func shouldAutoMeasure(measuredAt: Date?, now: Date, onPower: Bool, battery: Int?) -> Bool {
        if !onPower, let b = battery, b < minBattery { return false }
        guard let t = measuredAt else { return true }
        let age = now.timeIntervalSince(t)
        return age > autoMeasureAge || age < 0
    }

    /// "medido agora", "medido há 12 min", "medido há 3 h", "medido ontem", "medido há 5 dias".
    static func ago(_ at: Date, now: Date) -> String {
        let s = now.timeIntervalSince(at)
        if s < 60 { return "medido agora" }
        if s < 3600 { return "medido há \(Int(s / 60)) min" }
        if s < 86_400 { return "medido há \(Int(s / 3600)) h" }
        if s < 172_800 { return "medido ontem" }
        return "medido há \(Int(s / 86_400)) dias"
    }

    /// "52 GB", "3,1 GB", "480 MB" (vírgula decimal, como no resto da interface em português).
    static func size(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb).replacingOccurrences(of: ".", with: ",") }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
