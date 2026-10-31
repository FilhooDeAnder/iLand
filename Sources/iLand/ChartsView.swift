import SwiftUI

/// Aba "Gráficos" da visão geral: CPU, temperatura, rede e memória dos últimos 10 min + energia.
/// Desenho com Path (sem Swift Charts). Cabe no espaço da tabela (~210 pt), a altura da visão geral não muda.
struct ChartsView: View {
    let stats: SystemStats

    var body: some View {
        let pts = Self.window(stats.history)
        let now = pts.last?.t ?? Date()
        let xs = pts.map { 1 - now.timeIntervalSince($0.t) / History.window }
        let alerting = Set(stats.alerts.map(\.kind))
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                let cpu = pts.map(\.cpu)
                MiniChart(title: "CPU", value: pct(cpu.last), foot: range(cpu, pct),
                          xs: xs, lines: [(cpu, .white)], lo: 0, hi: 100, warn: (cpu.last ?? 0) >= 90)
                let temp = pts.map(\.temp).map { $0 > 0 ? $0 : .nan }
                let tv = temp.filter { !$0.isNaN }
                MiniChart(title: "Temperatura", value: tv.last.map { "\(Int($0)) °C" } ?? "--", foot: range(tv) { "\(Int($0 ?? 0))°" },
                          xs: xs, lines: [(temp, .white)], lo: (tv.min() ?? 40) - 3, hi: (tv.max() ?? 60) + 3,
                          warn: alerting.contains(.temperature) || alerting.contains(.thermal) || (tv.last ?? 0) >= AlertEngine.tempOn)
                let down = pts.map(\.down), up = pts.map(\.up)
                MiniChart(title: "Rede", value: "↓ " + Fmt.rate(down.last ?? 0), foot: "↑ \(Fmt.rate(up.last ?? 0)) · pico \(Fmt.rate(max(down.max() ?? 0, up.max() ?? 0)))",
                          xs: xs, lines: [(down, .white), (up, Color.white.opacity(0.4))], lo: 0, hi: max(down.max() ?? 0, up.max() ?? 0, 1024), warn: false)
                let mem = pts.map(\.mem)
                MiniChart(title: "Memória", value: pct(mem.last), foot: range(mem, pct),
                          xs: xs, lines: [(mem, .white)], lo: 0, hi: 100, warn: alerting.contains(.memory))
            }
            EnergyPanel(power: stats.power, apps: stats.energy)
        }
    }

    static func window(_ h: [HistoryPoint]) -> [HistoryPoint] {
        guard let last = h.last?.t else { return [] }
        return h.filter { last.timeIntervalSince($0.t) <= History.window }
    }

    private func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "--" }
    private func range(_ v: [Double], _ f: (Double?) -> String) -> String {
        v.isEmpty ? "sem dados ainda" : "mín \(f(v.min())) · máx \(f(v.max()))"
    }
}

struct MiniChart: View {
    let title: String
    let value: String
    let foot: String
    let xs: [Double]
    let lines: [([Double], Color)]
    let lo: Double
    let hi: Double
    let warn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 10)).foregroundColor(secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundColor(warn ? .orange : .white).lineLimit(1).fixedSize().layoutPriority(1)
            }
            ZStack {
                if let first = lines.first {
                    Sparkline(xs: xs, ys: norm(first.0), closed: true).fill(Color.white.opacity(0.07))
                }
                ForEach(lines.indices, id: \.self) { i in
                    Sparkline(xs: xs, ys: norm(lines[i].0), closed: false)
                        .stroke(warn && i == 0 ? Color.orange : lines[i].1, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                }
            }
            .frame(height: 40)
            Text(foot).font(.system(size: 9)).monospacedDigit().foregroundColor(secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.09)))
    }

    private func norm(_ v: [Double]) -> [Double] {
        let span = max(hi - lo, 0.001)
        return v.map { $0.isNaN ? .nan : min(1, max(0, ($0 - lo) / span)) }
    }
}

/// Linha (ou área, se `closed`) com x e y já normalizados em 0...1. NaN = buraco (sem leitura).
struct Sparkline: Shape {
    let xs: [Double]
    let ys: [Double]
    let closed: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        var started = false, firstX = 0.0, lastX = 0.0
        for (x, y) in zip(xs, ys) {
            guard !y.isNaN else { continue }
            let pt = CGPoint(x: r.minX + x * r.width, y: r.maxY - y * r.height)
            if started { p.addLine(to: pt) } else { p.move(to: pt); firstX = pt.x; started = true }
            lastX = pt.x
        }
        if closed && started {
            p.addLine(to: CGPoint(x: lastX, y: r.maxY))
            p.addLine(to: CGPoint(x: firstX, y: r.maxY))
            p.closeSubpath()
        }
        return p
    }
}

/// Potência do Mac (watts, da bateria) e os 5 apps com maior "impacto de energia" (coluna POWER do `top`).
struct EnergyPanel: View {
    let power: PowerReading?
    let apps: [AppEnergy]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps que mais gastam energia").font(.system(size: 10)).foregroundColor(secondary)
                    .help("Impacto de energia, a mesma medida do Monitor de Atividade. Atualiza a cada 10 s.")
                Spacer()
                Text(powerText).font(.system(size: 11)).monospacedDigit().foregroundColor(.white)
            }
            if let apps, !apps.isEmpty {
                let top = apps.first?.impact ?? 1
                VStack(spacing: 1) { ForEach(apps, id: \.name) { a in
                    HStack(spacing: 8) {
                        Text(a.name).font(.system(size: 11)).foregroundColor(.white).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Meter(fraction: a.impact / max(top, 0.1)).frame(width: 90)
                        Text(String(format: "%.1f", a.impact)).font(.system(size: 11)).monospacedDigit().foregroundColor(secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .frame(height: 15)
                } }
            } else {
                Text(apps == nil ? "medindo…" : "nenhum app gastando energia agora")
                    .font(.system(size: 11)).foregroundColor(secondary).frame(height: 15)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 114, maxHeight: 114, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.09)))
    }

    private var powerText: String {
        guard let p = power else { return "potência indisponível" }
        var parts: [String] = []
        if let w = p.system { parts.append(String(format: "Mac usando %.1f W", w)) }
        if let b = p.battery, abs(b) >= 0.1 {
            parts.append(b > 0 ? String(format: "bateria recebendo %.1f W", b) : String(format: "bateria fornecendo %.1f W", -b))
        }
        return parts.isEmpty ? "potência indisponível" : parts.joined(separator: " · ")
    }
}
