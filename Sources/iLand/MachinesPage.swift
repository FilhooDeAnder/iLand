import SwiftUI

/// Uma linha por máquina (bolinha, nome, CPU/RAM/disco, tempo ligada e o primeiro problema). Clicar abre o detalhe:
/// erros recentes, Explicar (Claude) e Abrir SSH. Altura fixa: lista e detalhe ocupam o mesmo espaço.
struct MachinesPage: View {
    @ObservedObject var machines: MachinesMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let alias = machines.focus, let e = machines.entries.first(where: { $0.alias == alias }) {
                detail(e)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(machines.entries) { e in
                            Button { machines.focus = e.alias } label: { row(e) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 14)   // a última linha passa inteira da sombra de baixo
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, NotchLayout.ear)
        .padding(.bottom, 16)
    }

    private func color(_ st: MachineState) -> Color {
        switch st {
        case .unknown, .noContact: .gray
        case .level(let l): l == .crit ? .red : (l == .warn ? .orange : .green)
        }
    }

    private func row(_ e: MachineEntry) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color(e.state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.alias).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    if let s = e.status {
                        Text("ligada há \(Fmt.age(s.uptimeS))").font(.system(size: 10)).foregroundColor(secondary)
                    }
                }
                Text(MachineRules.headline(e.state, e.status, now: Date()))
                    .font(.system(size: 11)).foregroundColor(e.state.alertLevel > .ok ? .orange : secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let s = e.status {
                meter("CPU", s.cpuPct); meter("RAM", s.ramPct); meter("disco", s.diskPct)
            }
        }
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    private func meter(_ label: String, _ pct: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(pct)%").font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundColor(pct >= 90 ? .red : (pct >= 80 ? .orange : .white))
            Text(label).font(.system(size: 9)).foregroundColor(secondary)
        }
        .frame(width: 34)
    }

    private func detail(_ e: MachineEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { machines.focus = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundColor(.white)
                Circle().fill(color(e.state)).frame(width: 8, height: 8)
                Text(e.alias).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Button(e.explaining ? "Pensando…" : "Explicar") { machines.explain(e.alias) }
                    .buttonStyle(CapsuleStyle()).disabled(e.explaining || e.status == nil)
                Button("Abrir SSH") { machines.openSSH(e.alias) }.buttonStyle(CapsuleStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !e.explanation.isEmpty {
                        Text(e.explanation).font(.system(size: 11)).foregroundColor(.white).textSelection(.enabled)
                    }
                    ForEach(e.status?.problems ?? [], id: \.text) { p in
                        Text("• " + p.text).font(.system(size: 11)).foregroundColor(p.level == .crit ? .red : .orange)
                    }
                    if let s = e.status {
                        Text("CPU \(s.cpuPct)% · RAM \(s.ramPct)% · swap \(s.swapPct)% · disco \(s.diskPct)% · ligada há \(Fmt.age(s.uptimeS))")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
