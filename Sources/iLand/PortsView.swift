import SwiftUI
import AppKit

/// Aba "Portas": quem escuta em cada porta (rolagem própria, cabe no espaço da tabela) e os 5 apps que mais usam a rede.
struct PortsView: View {
    let stats: SystemStats
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("Porta").frame(width: 62, alignment: .leading)
                    Text("Processo").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Escuta").frame(width: 52, alignment: .leading)
                    Text("Há quanto").frame(width: 52, alignment: .trailing)
                    Spacer().frame(width: 128)
                }
                .font(.system(size: 10)).foregroundColor(secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                if let rows = stats.ports, !rows.isEmpty {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) { ForEach(rows) { PortTableRow(row: $0, monitor: monitor) } }
                    }
                } else {
                    Text(stats.ports == nil ? "procurando portas…" : "nenhuma porta aberta pelos seus processos")
                        .font(.system(size: 11)).foregroundColor(secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.top, 6)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 132)
            NetPanel(apps: stats.netApps)
        }
    }
}

struct PortTableRow: View {
    let row: PortRow
    @ObservedObject var monitor: SystemMonitor
    @State private var hover = false

    var body: some View {
        let e = row.entry
        let app = AppFocus.gui(from: row.links[...])
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Text(String(e.port))
                if e.proto == "UDP" { Text("UDP").font(.system(size: 9)).foregroundColor(secondary) }
            }
            .frame(width: 62, alignment: .leading)
            HStack(spacing: 5) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                    .underline(app != nil && hover)
                    .contentShape(Rectangle())
                    .onTapGesture { if let app { AppFocus.go(to: app, tty: row.tty) } }
                    .help(app.map { "Abrir \($0.localizedName ?? row.name)" } ?? "")
                if !row.note.isEmpty {
                    Text(row.note).font(.system(size: 10, design: .monospaced)).foregroundColor(secondary)
                        .lineLimit(1).truncationMode(.middle).help(row.note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                Image(systemName: e.exposed ? "globe" : "lock.fill").font(.system(size: 9))
                Text(e.exposed ? "rede" : "local")
            }
            .foregroundColor(e.exposed ? .white : secondary)
            .frame(width: 52, alignment: .leading)
            .help(e.exposed ? "Exposta na rede: escuta em \(e.address == "*" ? "todas as interfaces" : e.address)" : "Só este Mac (\(e.address))")
            Text(row.age.map(Fmt.age) ?? "—").frame(width: 52, alignment: .trailing)
            HStack(spacing: 4) {
                if hover && e.proto == "TCP" {
                    Button("Abrir") { if let url = URL(string: "http://localhost:\(e.port)") { NSWorkspace.shared.open(url) } }
                        .buttonStyle(CapsuleStyle())
                        .help("Abrir http://localhost:\(e.port) no navegador")
                }
                if hover, row.canKill, let t = row.target { KillButton(targets: [t], quitApp: nil, monitor: monitor) }
            }
            .frame(width: 128, height: 20, alignment: .trailing)
        }
        .monospacedDigit()
        .font(.system(size: 12))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.white.opacity(0.07) : .clear))
        .onHover { hover = $0 }
    }
}

/// Os 5 apps com mais tráfego de rede externo agora (↓ recebendo, ↑ enviando), lado a lado.
struct NetPanel: View {
    let apps: [AppNet]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apps que mais usam a rede agora").font(.system(size: 10)).foregroundColor(secondary)
                .help("Tráfego fora deste Mac (sem localhost), medido pelo nettop a cada ~5 s.")
            if let apps, !apps.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(apps, id: \.name) { a in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.system(size: 11)).foregroundColor(.white).lineLimit(1).truncationMode(.middle)
                            Text("↓ " + Fmt.rate(a.down)).font(.system(size: 10))
                            Text("↑ " + Fmt.rate(a.up)).font(.system(size: 10)).foregroundColor(secondary)
                        }
                        .monospacedDigit().foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(apps.count..<5, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            } else {
                Text(apps == nil ? "medindo…" : "nenhum app usando a rede agora").font(.system(size: 11)).foregroundColor(secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.09)))
    }
}
