import SwiftUI
import AppKit

/// Janela só do disco (a página Disco do notch abre aqui por "Revisar ›" e "Abrir janela"). Escura como o notch.
/// Uma janela só: se já está aberta, vem para a frente. Fechar termina o du e o find em curso. As medidas ficam no arquivo do DiskModel.
/// Depuração: ILAND_DISK_WINDOW=<id da categoria ou 1> abre ao iniciar; ILAND_DISK_SELECT=<início do nome> escolhe uma linha; ILAND_WINDOW_SHOT=<arquivo.png> grava a janela.
final class DiskWindow: NSObject, NSWindowDelegate {
    static let shared = DiskWindow()
    var disk: DiskModel?
    var monitor: SystemMonitor?
    private var window: NSWindow?
    private var browser: DiskBrowser?

    func show(category: String? = nil) {
        guard let disk, let monitor else { return }
        if window == nil {
            let b = DiskBrowser(model: disk)
            if ProcessInfo.processInfo.environment["ILAND_DISK_DEMO"] != nil { b.loadDemo() }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Disco"
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(white: 0.07, alpha: 1)
            w.minSize = NSSize(width: 760, height: 560)
            w.delegate = self
            w.contentView = NSHostingView(rootView: DiskWindowView(browser: b, disk: disk, monitor: monitor) { [weak self] path, bytes, ok in
                self?.confirmTrash(path: path, bytes: bytes, ok)
            }.preferredColorScheme(.dark))
            w.center()
            if ProcessInfo.processInfo.environment["ILAND_DISK_WINDOW"] != nil { w.level = .floating }   // depuração: na frente de tudo
            window = w; browser = b
        }
        disk.measureIfStale()   // a semente do DiskModel pode ter horas
        if let category { browser?.choose(category) }
        if let t = ProcessInfo.processInfo.environment["ILAND_DISK_SELECT"] { browser?.select(browser?.rows.first { $0.title.hasPrefix(t) }?.id) }   // depuração
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.debugShot()
    }

    func stop() { browser?.stop() }

    func windowWillClose(_ notification: Notification) {
        browser?.stop()
        browser = nil; window = nil
    }

    private func confirmTrash(path: String, bytes: UInt64, _ ok: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "Mover para a Lixeira?"
        a.informativeText = "\(disk?.shortPath(path) ?? path)\n\(DiskRules.size(bytes))\n\nO espaço só volta quando você esvaziar a Lixeira."
        a.addButton(withTitle: "Mover para a Lixeira")
        a.addButton(withTitle: "Cancelar")
        guard let w = window else { return }
        a.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { ok() } }
    }
}

private let accent = Color.orange
private let panelFill = Color.white.opacity(0.045)

struct DiskWindowView: View {
    @ObservedObject var browser: DiskBrowser
    @ObservedObject var disk: DiskModel
    @ObservedObject var monitor: SystemMonitor
    let confirmTrash: (String, UInt64, @escaping () -> Void) -> Void

    var body: some View {
        let m = monitor.stats?.metrics
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Disco").font(.system(size: 22, weight: .semibold))
                if disk.measuring { Text("medindo…").font(.system(size: 11)).foregroundColor(secondary) }
                Spacer()
                if let m, m.diskTotal > 0 {
                    Text("\(DiskRules.size(m.diskFree)) livres de \(DiskRules.size(m.diskTotal))").font(.system(size: 14, design: .monospaced)).foregroundColor(secondary)
                }
            }
            if let m, m.diskTotal > 0 { Meter(fraction: m.diskUsedFraction, warn: m.diskUsedFraction > 0.9).frame(height: 8) }
            HStack(alignment: .top, spacing: 12) {
                sidebar.frame(width: 220)
                center
            }
            HStack(alignment: .top, spacing: 12) {
                detail
                chart.frame(width: 276)
            }
            .frame(height: 156)
        }
        .padding(24)
        .foregroundColor(.white)
        .frame(minWidth: 760, idealWidth: 920, minHeight: 560, idealHeight: 680)
        .background(Color(white: 0.07))   // explícito: a foto de depuração (cacheDisplay) não desenha o fundo da janela
    }

    private func panel<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().background(RoundedRectangle(cornerRadius: 8).fill(panelFill)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
    }

    private func caption(_ t: String) -> some View { Text(t).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(secondary) }

    // MARK: categorias

    private var sidebar: some View {
        panel {
            VStack(alignment: .leading, spacing: 2) {
                caption("CATEGORIAS").padding(.horizontal, 8).padding(.bottom, 6)
                if browser.sidebar.isEmpty {
                    Text(disk.measuring ? "Medindo as pastas…" : "Ainda não medido.").font(.system(size: 12)).foregroundColor(secondary).padding(.horizontal, 8)
                }
                ForEach(browser.sidebar) { c in
                    let on = c.id == browser.current?.id
                    Button { browser.choose(c.id) } label: {
                        HStack {
                            Text(c.title).font(.system(size: 14, weight: on ? .semibold : .regular)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(c.unmeasured ? "parcial" : DiskRules.size(c.bytes)).font(.system(size: 12, design: .monospaced)).foregroundColor(secondary)
                        }
                        .padding(.horizontal, 8).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? accent.opacity(0.2) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: pastas

    private var center: some View {
        panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    let crumbs = browser.crumbs
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, name in
                        if i > 0 { Text("›").foregroundColor(secondary) }
                        let last = i == crumbs.count - 1
                        Button { browser.back(to: i) } label: {
                            Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).foregroundColor(last ? .white : secondary)
                        }
                        .buttonStyle(.plain).disabled(last)
                    }
                    if crumbs.count == 1 { Text("› todas as pastas").font(.system(size: 15)).foregroundColor(secondary) }
                    Spacer()
                    if browser.busy { ProgressView().controlSize(.small) }
                    if let at = browser.measuredAt { MeasuredAgo(at: at) }
                    Button { monitor.refreshDisk(); browser.reload() } label: { Text(browser.updating ? "medindo…" : "Atualizar") }
                        .buttonStyle(ChipStyle()).disabled(browser.updating || browser.moving).help("Medir de novo, sem olhar a idade da medida")
                }
                if let n = browser.notice { Text(n).font(.system(size: 11)).foregroundColor(accent) }
                if let e = browser.errorText { Text(e).font(.system(size: 11)).foregroundColor(accent) }
                let rows = browser.rows
                let top = max(1, rows.map(\.bytes).max() ?? 1)
                if rows.isEmpty && !browser.busy && browser.current != nil { Text("Nada medido aqui.").font(.system(size: 12)).foregroundColor(secondary).padding(.top, 6) }
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { r in rowView(r, top: top) }
                        if browser.hiddenRows > 0 {
                            Text("+ \(browser.hiddenRows) menores").font(.system(size: 11)).foregroundColor(secondary).padding(.vertical, 8)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func rowView(_ r: DiskRow, top: UInt64) -> some View {
        let on = browser.selection == r.id
        let hint = r.hint?.short
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.system(size: 14, weight: r.virtual ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                if let hint { Text(hint).font(.system(size: 11, design: .monospaced)).foregroundColor(secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(r.virtual ? accent : Color.white.opacity(0.5)).frame(width: max(3, g.size.width * Double(r.bytes) / Double(top)))
                }
            }
            .frame(width: 190, height: 8)
            Text(DiskRules.size(r.bytes)).font(.system(size: 12, design: .monospaced)).frame(width: 64, alignment: .trailing)
            Button { browser.enter(r) } label: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).frame(width: 18) }
                .buttonStyle(.plain).foregroundColor(r.enterable ? secondary : .clear).disabled(!r.enterable)
                .help("Abrir e medir as subpastas")
        }
        .padding(.horizontal, 8).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? accent.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { browser.enter(r) }
        .onTapGesture { browser.select(r.id) }
    }

    // MARK: detalhe

    private var detail: some View {
        panel {
            VStack(alignment: .leading, spacing: 5) {
                if let r = browser.row(id: browser.selection) { detailBody(r) }
                else { Text("Clique em uma linha para ver o detalhe.").font(.system(size: 12)).foregroundColor(secondary) }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func detailBody(_ r: DiskRow) -> some View {
        let hint = r.hint
        HStack(alignment: .firstTextBaseline) {
            Text(r.virtual ? "node_modules dos projetos" : r.title).font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(DiskRules.size(r.bytes)).font(.system(size: 14, design: .monospaced)).foregroundColor(r.virtual ? accent : secondary)
        }
        if let p = r.path { Text(disk.shortPath(p)).font(.system(size: 11, design: .monospaced)).foregroundColor(secondary).lineLimit(1).truncationMode(.middle) }
        if r.virtual {
            let stale = browser.nodeModules.filter { ($0.modified.map { Date().timeIntervalSince($0) / 86_400 } ?? 0) > Double(DiskRules.staleDays) }.count
            Text("Dependências de \(browser.nodeCount) projetos. Voltam com npm install." + (stale > 0 ? " \(stale) de \(browser.nodeModules.count) sem uso há mais de 2 meses." : ""))
                .font(.system(size: 13)).foregroundColor(secondary).lineLimit(2)
        } else {
            if let h = hint { Text(h.sentence).font(.system(size: 13)).foregroundColor(secondary).lineLimit(2) }
            if let d = r.modified { Text("Última modificação: \(Self.date(d))").font(.system(size: 12)).foregroundColor(secondary) }
        }
        Spacer(minLength: 4)
        HStack(spacing: 10) {
            if let p = r.path {
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }.buttonStyle(CapsuleStyle())
            }
            if browser.selectedCanTrash, let p = r.path {
                Button(browser.moving ? "Movendo…" : "Mover para a Lixeira") { confirmTrash(p, r.bytes) { browser.trash(p, bytes: r.bytes) } }
                    .buttonStyle(CapsuleStyle(tint: accent)).disabled(browser.moving || browser.measuring)
                    .help(browser.measuring ? "Espere a medida terminar" : "")
            }
        }
    }

    private static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR"); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: d)
    }

    // MARK: últimos 30 dias

    private var chart: some View {
        panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    caption("ÚLTIMOS 30 DIAS" + (browser.categoryID == nil ? "" : browser.current.map { " · " + $0.title.uppercased() } ?? ""))
                    Spacer()
                }
                if let s = browser.series {
                    Text(DiskRules.signedSize(s.delta)).font(.system(size: 14, design: .monospaced))
                        .foregroundColor(s.delta > 0 ? accent : .green).frame(maxWidth: .infinity, alignment: .trailing)
                    HistoryLine(series: s).stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                } else {
                    Spacer()
                    Text("Histórico começa hoje").font(.system(size: 12)).foregroundColor(secondary).frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(14)
        }
    }
}

/// A linha do gráfico: x pelo dia (30 dias à esquerda, hoje à direita), y entre o menor e o maior valor.
struct HistoryLine: Shape {
    let series: DiskRules.Series
    func path(in r: CGRect) -> Path {
        let values = series.points.map { Double($0.bytes) }
        let lo = values.min() ?? 0, span = max(1, (values.max() ?? 1) - lo)
        var p = Path()
        for (i, pt) in series.points.enumerated() {
            let x = r.minX + r.width * CGFloat(29 - pt.day) / 29
            let y = r.maxY - r.height * CGFloat((values[i] - lo) / span) * 0.9 - r.height * 0.05
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}
