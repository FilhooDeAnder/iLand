// Uso: swiftc -parse-as-library Sources/iLand/DiskRules.swift Sources/iLand/DiskModel.swift Tests/Unit/test_disk.swift -o /tmp/t_disk && /tmp/t_disk
import Foundation

@main struct DiskCheck {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("iland-disk-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home").path
        for d in [".cache/uv", ".npm/_cacache", "Library/Caches/com.x", "Projetos/app", "outside"] {
            try fm.createDirectory(atPath: d == "outside" ? base.appendingPathComponent(d).path : "\(home)/\(d)", withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: "\(home)/.cache/link", withDestinationPath: base.appendingPathComponent("outside").path)
        try fm.createSymbolicLink(atPath: "\(home)/viaLink", withDestinationPath: "\(home)/.cache")

        // Guarda de segurança.
        assert(DiskRules.canTrash("\(home)/.cache/uv", home: home), "filho de ~/.cache")
        assert(DiskRules.canTrash("\(home)/.npm/_cacache", home: home), "filho de ~/.npm")
        assert(DiskRules.canTrash("\(home)/Library/Caches/com.x", home: home), "filho de Library/Caches")
        assert(!DiskRules.canTrash("\(home)/.cache", home: home), "a raiz não")
        assert(!DiskRules.canTrash("\(home)/.cache/", home: home), "a raiz com barra final não")
        assert(!DiskRules.canTrash("\(home)/Library/Caches", home: home), "a raiz de Library/Caches não")
        assert(!DiskRules.canTrash("\(home)/.cache/uv/sub", home: home), "neto não")
        assert(!DiskRules.canTrash("\(home)/Projetos/app", home: home), "fora das raízes")
        assert(!DiskRules.canTrash(home, home: home), "a própria home")
        assert(!DiskRules.canTrash("\(home)/.cache/../Projetos", home: home), "com ..")
        assert(!DiskRules.canTrash("\(home)/.cache/uv/..", home: home), "com .. no fim")
        assert(!DiskRules.canTrash("\(home)/.cache/.", home: home), "com . no fim")
        assert(!DiskRules.canTrash("\(home)/Projetos/../.cache/uv", home: home), "com .. que cairia dentro da raiz")
        fm.changeCurrentDirectoryPath(home)
        assert(!DiskRules.canTrash(".cache/uv", home: home), "relativo (aqui cairia dentro da raiz)")
        assert(!DiskRules.canTrash("", home: home), "vazio")
        assert(!DiskRules.canTrash("\(home)/.cache/link", home: home), "filho que é link para fora não")
        assert(DiskRules.canTrash("\(home)/viaLink/uv", home: home), "caminho por um link que leva à raiz resolve para filho da raiz")
        assert(!DiskRules.canTrash("\(home)/.cache-extra/uv", home: home), "prefixo parecido não")

        // Regra da janela: recriável dentro de um projeto de ~/Projetos, mais o que canTrash já aceita.
        let nm = "\(home)/Projetos/app/node_modules"
        for d in ["Projetos/app/node_modules", "Projetos/app/packages/x/node_modules", "Projetos/app/.venv", "Projetos/app/src", "Projetos/build", "Documents", ".claude/projects/build", "Library/Application Support/Claude/build"] {
            try fm.createDirectory(atPath: "\(home)/\(d)", withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: "\(home)/Projetos/app/dist", withDestinationPath: "\(home)/Documents")
        try fm.createSymbolicLink(atPath: "\(home)/Projetos/app/target", withDestinationPath: "\(home)/.claude/projects")
        try fm.createSymbolicLink(atPath: "\(home)/.cache/toClaude", withDestinationPath: "\(home)/.claude")
        assert(DiskRules.canTrashItem(nm, home: home), "node_modules de um projeto")
        assert(DiskRules.canTrashItem("\(home)/Projetos/app/packages/x/node_modules", home: home), "node_modules mais fundo")
        assert(DiskRules.canTrashItem("\(home)/Projetos/app/.venv", home: home), ".venv")
        assert(DiskRules.canTrashItem("\(home)/.cache/uv", home: home), "o que canTrash aceita")
        assert(!DiskRules.canTrashItem("\(home)/Projetos", home: home), "~/Projetos não")
        assert(!DiskRules.canTrashItem("\(home)/Projetos/app", home: home), "o projeto inteiro não")
        assert(!DiskRules.canTrashItem("\(home)/Projetos/build", home: home), "pasta recriável no lugar de um projeto = o projeto inteiro")
        assert(!DiskRules.canTrashItem("\(home)/Projetos/app/src", home: home), "pasta que não é recriável")
        assert(!DiskRules.canTrashItem("\(home)/Projetos/app/node_modules/..", home: home), "com ..")
        assert(!DiskRules.canTrashItem("\(home)/Projetos/../Documents/node_modules", home: home), "com .. no meio")
        assert(!DiskRules.canTrashItem("\(home)/Projetos/app/dist", home: home), "link recriável que aponta para fora de Projetos")
        assert(!DiskRules.canTrashItem("\(home)/Projetos/app/target", home: home), "link recriável que aponta para ~/.claude")
        assert(!DiskRules.canTrashItem("\(home)/.cache/toClaude", home: home), "filho de cache que é link para ~/.claude")
        assert(!DiskRules.canTrashItem("\(home)/.claude/projects/build", home: home), "dentro de ~/.claude")
        assert(!DiskRules.canTrashItem("\(home)/Library/Application Support/Claude/build", home: home), "dentro de Application Support/Claude")
        assert(!DiskRules.canTrashItem("node_modules", home: home), "relativo")
        // build, dist e target só ao lado de um arquivo de projeto.
        for d in ["Projetos/plain/build", "Projetos/plain/dist", "Projetos/plain/target", "Projetos/js/build", "Projetos/rs/target", "Projetos/plain/.next"] {
            try fm.createDirectory(atPath: "\(home)/\(d)", withIntermediateDirectories: true)
        }
        fm.createFile(atPath: "\(home)/Projetos/js/package.json", contents: Data())
        fm.createFile(atPath: "\(home)/Projetos/rs/Cargo.toml", contents: Data())
        for n in ["build", "dist", "target"] { assert(!DiskRules.canTrashItem("\(home)/Projetos/plain/\(n)", home: home), "\(n) sem marcador de projeto") }
        assert(DiskRules.canTrashItem("\(home)/Projetos/js/build", home: home), "build ao lado de package.json")
        assert(DiskRules.canTrashItem("\(home)/Projetos/rs/target", home: home), "target ao lado de Cargo.toml")
        assert(DiskRules.canTrashItem("\(home)/Projetos/plain/.next", home: home), ".next não pede marcador")
        // Só a trava de .claude pega aqui: Projetos aponta para dentro de ~/.claude, e o resto da regra aceitaria.
        let home2 = base.appendingPathComponent("home2").path
        try fm.createDirectory(atPath: "\(home2)/.claude/app/node_modules", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: "\(home2)/Projetos", withDestinationPath: "\(home2)/.claude")
        assert(!DiskRules.canTrashItem("\(home2)/Projetos/app/node_modules", home: home2), "dentro de ~/.claude, mesmo por um link")
        try fm.createDirectory(atPath: "\(home2)/Library/Application Support/Claude/app/node_modules", withIntermediateDirectories: true)
        try fm.removeItem(atPath: "\(home2)/Projetos")
        try fm.createSymbolicLink(atPath: "\(home2)/Projetos", withDestinationPath: "\(home2)/Library/Application Support/Claude")
        assert(!DiskRules.canTrashItem("\(home2)/Projetos/app/node_modules", home: home2), "dentro de Application Support/Claude, mesmo por um link")

        // Dicas.
        var cal0 = Calendar(identifier: .gregorian); cal0.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let t0 = cal0.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
        func ago(_ d: Int) -> Date { t0.addingTimeInterval(-Double(d) * 86_400) }
        func hint(_ p: String, _ d: Int?) -> String? { DiskRules.hint(path: p, modified: d.map(ago), now: t0, home: home)?.short }
        assert(hint("\(home)/Projetos/a/node_modules", 1) == "recriável: npm install")
        assert(hint("\(home)/Projetos/a/node_modules", 200) == "recriável: npm install", "recriável vence sem uso")
        assert(hint("\(home)/Projetos/a/.venv", nil) == "recriável: ambiente Python" && hint("\(home)/Projetos/a/venv", nil) == "recriável: ambiente Python")
        for n in ["DerivedData", ".next", "dist", "build", "target", "__pycache__", ".gradle"] { assert(hint("\(home)/Projetos/a/\(n)", 1) == "recriável: build", n) }
        assert(hint("\(home)/.cache/uv", 1) == "cache" && hint("\(home)/Library/Caches/com.x", 1) == "cache")
        assert(hint("\(home)/.cache/uv/sub", 1) == nil, "neto de cache não")
        assert(hint("\(home)/Projetos/crm", 61) == "sem uso há 2 meses" && hint("\(home)/Projetos/crm", 100) == "sem uso há 3 meses")
        assert(hint("\(home)/Projetos/crm", 60) == nil, "60 dias ainda não")
        assert(hint("\(home)/Projetos/crm", nil) == nil && hint("\(home)/Projetos/crm", 5) == nil, "sem dica")

        let gb: UInt64 = 1_073_741_824
        // Medida de fundo: só vale se a pasta não foi mexida (Mover) desde que ela começou.
        assert(DiskRules.refreshAction(started: 0, current: 0) == .store)
        assert(DiskRules.refreshAction(started: 0, current: 1) == .remeasure, "Mover durante o du: mede de novo")

        // Histórico de 30 dias.
        func snap(_ d: Int, _ a: UInt64, _ b: UInt64) -> DiskRules.Snapshot { DiskRules.Snapshot(day: DiskRules.dayKey(ago(d), calendar: cal0), sizes: ["a": a, "b": b]) }
        let hs = [snap(40, 1, 1), snap(20, 10, 5), snap(10, 12, 5), snap(0, 13, 7)]
        let all = DiskRules.series(history: hs, category: nil, now: t0, calendar: cal0)!
        assert(all.points.map(\.day) == [20, 10, 0], "a foto de 40 dias fica de fora")
        assert(all.delta == 5, "total: 20 -> 15 ... soma de 15 até 20")
        let only = DiskRules.series(history: hs, category: "b", now: t0, calendar: cal0)!
        assert(only.delta == 2 && only.points.map(\.bytes) == [5, 5, 7], "só a categoria escolhida")
        assert(DiskRules.series(history: [snap(0, 1, 1)], category: nil, now: t0, calendar: cal0) == nil, "1 dia: Histórico começa hoje")
        assert(DiskRules.series(history: [snap(50, 1, 1), snap(0, 1, 1)], category: nil, now: t0, calendar: cal0) == nil, "só 1 dia dentro dos 30")
        assert(DiskRules.series(history: hs, category: "zzz", now: t0, calendar: cal0) == nil, "categoria sem foto")
        assert(DiskRules.signedSize(Int64(gb) * 12) == "+12 GB" && DiskRules.signedSize(-Int64(gb) * 21 / 10) == "−2,1 GB", "sinal")

        // Cresceu em 7 dias, com fuso fixo (a máquina do dono não é UTC).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        func date(_ s: String, _ hour: Int = 12) -> Date {
            let p = s.split(separator: "-").compactMap { Int($0) }
            return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour))!
        }
        let now = date("2026-11-05")
        let hist = [
            DiskRules.Snapshot(day: "2026-10-20", sizes: ["a": 10 * gb]),                              // velha demais, mas a mais recente com 7+ dias é a de 29/10
            DiskRules.Snapshot(day: "2026-10-29", sizes: ["a": 10 * gb, "b": 5 * gb, "c": 2 * gb, "d": 9 * gb]),
            DiskRules.Snapshot(day: "2026-11-03", sizes: ["a": 99 * gb]),
        ]
        let cur = ["a": 11 * gb, "b": 8 * gb, "c": 4 * gb, "d": 8 * gb, "e": 50 * gb]
        let g = DiskRules.growth(current: cur, history: hist, now: now, calendar: cal)!
        assert(g.days == 7, "base de 29/10 = 7 dias")
        assert(g.items.map(\.id) == ["b", "c"], "as 2 que mais cresceram; d encolheu, e não tinha foto")
        assert(g.items.map(\.bytes) == [3 * gb, 2 * gb])

        // Menos de 7 dias: usa a foto mais velha que existe, nunca a de hoje.
        let young = [DiskRules.Snapshot(day: "2026-11-03", sizes: ["a": 10 * gb]), DiskRules.Snapshot(day: "2026-11-05", sizes: ["a": 12 * gb])]
        let g2 = DiskRules.growth(current: ["a": 12 * gb], history: young, now: now, calendar: cal)!
        assert(g2.days == 2 && g2.items.first?.bytes == 2 * gb, "2 dias de histórico")
        // Só a foto de hoje (ou nada): "Histórico começa hoje".
        assert(DiskRules.growth(current: cur, history: [young[1]], now: now, calendar: cal) == nil)
        assert(DiskRules.growth(current: cur, history: [], now: now, calendar: cal) == nil)
        // Nada cresceu: lista vazia, mas há base.
        assert(DiskRules.growth(current: ["a": 1], history: hist, now: now, calendar: cal)!.items.isEmpty)
        // A virada do dia vem do fuso do negócio: 23:30 em São Paulo ainda é dia 5 (em UTC já seria 6).
        assert(DiskRules.dayKey(date("2026-11-05", 23), calendar: cal) == "2026-11-05")

        // Foto diária: só a primeira do dia vale; guarda 60 dias.
        var h = DiskRules.record([], sizes: ["a": 1], now: now, calendar: cal)
        h = DiskRules.record(h, sizes: ["a": 2], now: date("2026-11-05", 20), calendar: cal)
        assert(h.count == 1 && h[0].sizes["a"] == 1, "a segunda medida do dia não sobrescreve")
        h = DiskRules.record(h, sizes: ["a": 9, "b": 7], now: date("2026-11-05", 21), calendar: cal)
        assert(h.count == 1 && h[0].sizes == ["a": 1, "b": 7], "medida boa mais tarde completa a foto com o que faltava, sem mexer no que já tinha")
        // Foto parcial (uma pasta lenta ficou de fora): o "cresceu" compara só as categorias das duas fotos.
        let partial = [DiskRules.Snapshot(day: "2026-10-29", sizes: ["a": 10 * gb])]
        let gp = DiskRules.growth(current: ["a": 12 * gb, "slow": 99 * gb], history: partial, now: now, calendar: cal)!
        assert(gp.items.map(\.id) == ["a"], "categoria que não estava na foto antiga não entra")
        for i in 1...70 { h = DiskRules.record(h, sizes: [:], now: cal.date(byAdding: .day, value: i, to: now)!, calendar: cal) }
        assert(h.count == 60 && h.last!.day == DiskRules.dayKey(cal.date(byAdding: .day, value: 70, to: now)!, calendar: cal), "60 dias")

        // Medida ruim não grava a foto do dia; uma medida boa mais tarde grava.
        typealias R = DiskRules.Reading
        assert(R(status: 0, bytes: 0).good, "Lixeira vazia (0 sem erro) é medida boa")
        assert(R(exists: false, found: false, bytes: 0).good, "pasta que não existe não conta")
        assert(!R(timedOut: true).good, "estourou o prazo")
        assert(!R(found: false).good, "du não imprimiu a pasta")
        assert(!R(status: 1, bytes: 0).good, "0 com erro em pasta que existe")
        assert(R(status: 1, bytes: 3 * gb).good, "erro de permissão em parte dos arquivos, mas mediu: vale")

        // DuRunner: mede de verdade, estoura o prazo, e stop() termina o que roda e impede novos.
        let runner = DuRunner()
        let (r1, kids) = runner.du("\(home)/Projetos", deadline: 20)
        assert(r1.good && kids.contains { $0.path == "\(home)/Projetos/app" }, "du mede a pasta e os filhos")
        let slow = runner.run("/bin/sleep", ["30"], deadline: 0.3)
        assert(slow.timedOut, "prazo estourado")
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { runner.stop() }
        assert(runner.run("/bin/sleep", ["30"], deadline: 20).status != 0 && Date().timeIntervalSince(started) < 5, "stop termina o processo em curso")
        assert(runner.run("/bin/echo", ["x"], deadline: 5).timedOut, "depois de stop não roda mais")

        // Medida automática: idade (24 h) e bateria (30%).
        let tm = Date(timeIntervalSince1970: 1_800_000_000), hour: TimeInterval = 3600
        func auto(_ ageH: Double?, power: Bool = true, battery: Int? = nil) -> Bool {
            DiskRules.shouldAutoMeasure(measuredAt: ageH.map { tm.addingTimeInterval(-$0 * hour) }, now: tm, onPower: power, battery: battery)
        }
        assert(auto(nil), "nunca medida: mede")
        assert(!auto(23.9) && !auto(24) && auto(24.1), "só com mais de 24 h")
        assert(auto(-1), "medida no futuro (relógio voltou) conta como velha")
        assert(!auto(48, power: false, battery: 29), "bateria abaixo de 30% sem tomada: não mede")
        assert(auto(48, power: false, battery: 30), "bateria em 30% ainda mede")
        assert(auto(48, power: true, battery: 5), "na tomada mede mesmo com bateria baixa")
        assert(auto(48, power: false, battery: nil), "sem leitura de bateria mede")
        assert(!auto(1, power: false, battery: 90), "bateria boa não anula a idade")
        let at = { (h: Double) in DiskRules.ago(tm.addingTimeInterval(-h * hour), now: tm) }
        assert(at(0.001) == "medido agora" && at(0.2) == "medido há 12 min" && at(3) == "medido há 3 h" && at(30) == "medido ontem" && at(120) == "medido há 5 dias", "texto da idade")

        // Depois do Mover: subtrai da lista e do total, sem passar de zero.
        assert(DiskRules.shrink(5 * gb, by: 2 * gb) == 3 * gb && DiskRules.shrink(gb, by: 2 * gb) == 0, "subtrai sem passar de zero")
        assert(DiskRules.adjusted(5 * gb, by: -Int64(gb)) == 4 * gb && DiskRules.adjusted(gb, by: Int64(gb)) == 2 * gb && DiskRules.adjusted(gb, by: -Int64(3 * gb)) == 0, "diferença com sinal")
        let kidsBefore = [DiskItem(path: "/r/a", bytes: 10 * gb), DiskItem(path: "/r/b", bytes: 4 * gb), DiskItem(path: "/r/ab", bytes: gb)]
        assert(DiskRules.removing(path: "/r/b", bytes: 4 * gb, from: kidsBefore).map(\.path) == ["/r/a", "/r/ab"], "filho direto movido sai da lista")
        let inner = DiskRules.removing(path: "/r/a/node_modules", bytes: 3 * gb, from: kidsBefore)
        assert(inner.map(\.bytes) == [7 * gb, 4 * gb, gb], "item dentro de um filho: só esse filho encolhe")
        assert(DiskRules.removing(path: "/r/ab/x", bytes: gb / 2, from: kidsBefore).map(\.bytes) == [10 * gb, 4 * gb, gb / 2], "/r/ab/x não encolhe /r/a (prefixo sem barra)")

        // DiskModel: o Mover segura a medida completa, e raiz sem lista medida não ganha lista vazia.
        let model = DiskModel(cacheURL: base.appendingPathComponent("model-cache.json"))
        model.beginMove()
        model.measure()
        assert(model.moving && !model.measuring, "measure() espera o Mover")
        model.beginMove(); model.endMove()
        assert(model.moving, "dois Movers: um terminar não solta o outro")
        model.endMove()
        assert(!model.moving, "sem Mover em curso")
        model.removed([(NSHomeDirectory() + "/Projetos/iland-teste-inexistente/x/y", gb)])
        assert(model.children[NSHomeDirectory() + "/Projetos"] == nil, "removed não grava lista vazia para raiz sem medida")

        // Cache em disco: ida e volta, arquivo ruim ou de outra versão, pasta que sumiu, teto de pastas.
        let url = base.appendingPathComponent("cache/disk-cache.json")
        var c = DiskCache()
        c.categoriesAt = tm
        c.categories = [DiskCache.Cat(id: "tools", bytes: 5 * gb, unmeasured: false)]
        c.children = ["\(home)/.cache": [DiskItem(path: "\(home)/.cache/uv", bytes: 2 * gb), DiskItem(path: "\(home)/.cache/sumiu", bytes: gb)]]
        c.setFolder("\(home)/Projetos", [DiskEntry(path: "\(home)/Projetos/app", bytes: gb, modified: tm, isDir: true), DiskEntry(path: "\(home)/Projetos/x", bytes: 5, modified: nil, isDir: false)], at: tm)
        c.nodeModules = DiskCache.Folder(at: tm, entries: [DiskEntry(path: nm, bytes: 7, modified: tm, isDir: true)])
        c.save(to: url)
        assert(DiskCache.load(from: url) == c, "ida e volta do JSON")
        assert(!fm.fileExists(atPath: url.path + ".tmp") && DiskCache.load(from: base.appendingPathComponent("nao-existe.json")) == nil, "sem arquivo: nil")
        try Data("{ isto não é json".utf8).write(to: url)
        assert(DiskCache.load(from: url) == nil, "JSON corrompido é ignorado")
        try Data().write(to: url)
        assert(DiskCache.load(from: url) == nil, "arquivo vazio é ignorado")
        try Data(#"{"version":0,"categories":[],"children":{},"folders":{}}"#.utf8).write(to: url)
        assert(DiskCache.load(from: url) == nil, "versão antiga é ignorada")
        try Data(#"{"version":1}"#.utf8).write(to: url)
        assert(DiskCache.load(from: url) == nil, "campos que faltam: ignorado")
        let alive = c.pruned()
        assert(alive.folders["\(home)/Projetos"]!.entries.map(\.path) == ["\(home)/Projetos/app"], "pasta que não existe mais sai da lista")
        assert(alive.children["\(home)/.cache"]!.map(\.path) == ["\(home)/.cache/uv"] && alive.nodeModules!.entries.count == 1, "filho e node_modules que sumiram saem; os que existem ficam")
        var many = DiskCache()
        for i in 0..<(DiskCache.maxFolders + 5) { many.setFolder("/p\(i)", [], at: tm.addingTimeInterval(Double(i))) }
        assert(many.folders.count == DiskCache.maxFolders && many.folders["/p0"] == nil && many.folders["/p\(DiskCache.maxFolders + 4)"] != nil, "teto: sai a mais velha")

        assert(DiskRules.size(52 * gb) == "52 GB" && DiskRules.size(gb * 31 / 10) == "3,1 GB" && DiskRules.size(480 << 20) == "480 MB")
        print("test_disk ok")
    }
}
