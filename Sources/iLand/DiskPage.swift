import SwiftUI

/// Página Disco: espaço livre, o que mais ocupa (5 maiores), o que cresceu e a limpeza de caches pela Lixeira.
/// A confirmação troca a lista no mesmo espaço (o notch é pequeno). A lista rola quando não cabe.
struct DiskPage: View {
    @ObservedObject var disk: DiskModel
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        let m = monitor.stats?.metrics
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Disco").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Spacer()
                if let m, m.diskTotal > 0 {
                    Text("\(DiskRules.size(m.diskFree)) livres de \(DiskRules.size(m.diskTotal))").font(.system(size: 11)).monospacedDigit().foregroundColor(secondary)
                }
                Button { monitor.refreshDisk(); disk.measure() } label: { Text(disk.measuring ? "medindo…" : "Atualizar") }
                    .buttonStyle(ChipStyle()).disabled(disk.measuring || disk.moving).help("Medir de novo, sem olhar a idade da medida")
            }
            if let m, m.diskTotal > 0 { Meter(fraction: m.diskUsedFraction, warn: m.diskUsedFraction > 0.9) }
            if disk.confirming { confirm } else { overview }
        }
        .padding(.horizontal, 18)
        .padding(.top, NotchLayout.ear)
        .padding(.bottom, 16)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .medium)).foregroundColor(secondary)
    }

    private var overview: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if let r = disk.result { Text(r).font(.system(size: 10)).foregroundColor(.orange).padding(.bottom, 4) }
                HStack(spacing: 6) {
                    label(disk.measuring ? "O QUE OCUPA · MEDINDO…" : "O QUE OCUPA")
                    if let at = disk.measuredAt { MeasuredAgo(at: at, size: 9) }
                }
                .padding(.bottom, 2)
                if !disk.measured { Text(disk.measuring ? "Medindo as pastas…" : "Ainda não medido.").font(.system(size: 11)).foregroundColor(secondary).padding(.vertical, 4) }
                ForEach(disk.top) { c in
                    HStack(spacing: 8) {
                        Text(c.title).font(.system(size: 12)).foregroundColor(.white).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(c.unmeasured ? "não medida" : DiskRules.size(c.bytes)).font(.system(size: 11)).monospacedDigit().foregroundColor(c.unmeasured ? .orange : secondary)
                        Button { c.action == .clean ? disk.startConfirm() : DiskWindow.shared.show(category: c.id) } label: {
                            Text(c.action == .clean ? "Limpar ›" : "Revisar ›").font(.system(size: 11, weight: c.action == .clean ? .semibold : .regular))
                                .foregroundColor(c.action == .clean ? .white : secondary).frame(width: 62, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .disabled(c.action == .clean && !disk.cleanable)
                    }
                    .frame(height: 22)
                }
                if disk.measured {
                    label(growthTitle).padding(.top, 8).padding(.bottom, 2)
                    if let g = disk.growth {
                        if g.items.isEmpty { Text("Nada cresceu.").font(.system(size: 11)).foregroundColor(secondary).frame(height: 22) }
                        ForEach(g.items, id: \.id) { it in
                            HStack {
                                Text(disk.categories.first { $0.id == it.id }?.title ?? it.id).font(.system(size: 12)).foregroundColor(.white)
                                Spacer()
                                Text("+" + DiskRules.size(it.bytes)).font(.system(size: 11)).monospacedDigit().foregroundColor(.orange)
                            }
                            .frame(height: 22)
                        }
                    } else {
                        Text("Histórico começa hoje.").font(.system(size: 11)).foregroundColor(secondary).frame(height: 22)
                    }
                    HStack(spacing: 8) {
                        if disk.cleanable { Button("Revisar e limpar") { disk.startConfirm() }.buttonStyle(CapsuleStyle(fill: true)) }
                        Button("Abrir janela") { DiskWindow.shared.show() }.buttonStyle(CapsuleStyle(fill: true))
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 14)
            }
        }
    }

    private var growthTitle: String {
        guard let d = disk.growth?.days else { return "CRESCEU" }
        return d >= 7 ? "CRESCEU EM 7 DIAS" : "CRESCEU EM \(d) \(d == 1 ? "DIA" : "DIAS")"
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("MOVER PARA A LIXEIRA?")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(disk.items) { it in
                        Button { disk.toggle(it.path) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: disk.selected.contains(it.path) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12)).foregroundColor(disk.selected.contains(it.path) ? .white : secondary)
                                Text(disk.shortPath(it.path)).font(.system(size: 11)).foregroundColor(.white).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(DiskRules.size(it.bytes)).font(.system(size: 11)).monospacedDigit().foregroundColor(secondary)
                            }
                            .frame(height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 104)
            HStack(spacing: 8) {
                Text("Total \(DiskRules.size(disk.selectedBytes))").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundColor(.white)
                Spacer()
                Button("Cancelar") { disk.cancel() }.buttonStyle(CapsuleStyle()).disabled(disk.moving)
                Button(disk.moving ? "Movendo…" : "Mover") { disk.moveSelected() }
                    .buttonStyle(CapsuleStyle(tint: .orange)).disabled(disk.selected.isEmpty || disk.moving || disk.measuring)
            }
        }
    }
}

/// "medido há 3 h": se atualiza sozinho a cada minuto.
struct MeasuredAgo: View {
    let at: Date
    var size: CGFloat = 11
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            Text(DiskRules.ago(at, now: ctx.date)).font(.system(size: size)).foregroundColor(secondary)
        }
    }
}
