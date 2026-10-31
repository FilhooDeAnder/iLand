import SwiftUI

/// Página do assistente no notch: a última troca da conversa (a mesma da janela) e o campo. "Abrir" leva à janela.
struct ClaudePage: View {
    @ObservedObject var agent: AgentController
    @ObservedObject var brain: BrainClient

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                OrbView(state: agent.orb)
                TextField(brain.available ? "Fale com o assistente…" : "Perguntar ao Claude…", text: $agent.draft)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                    .onSubmit { agent.send() }
                Button(agent.busy ? "Parar" : "Enviar") { agent.busy ? agent.cancel() : agent.send() }
                    .buttonStyle(CapsuleStyle(tint: agent.busy ? .orange : .white))
                Button { MainWindow.shared.show(.assistant) } label: { Image(systemName: "macwindow") }
                    .buttonStyle(ChipStyle()).help("Abrir a janela do iLand")
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06))
                if let last = agent.lastAssistant {
                    ScrollView(.vertical, showsIndicators: false) {
                        AgentMessageView(message: last, agent: agent, compact: true).padding(8)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pergunte sobre o seu dia, projetos, timer e tasks.").font(.system(size: 11)).foregroundColor(secondary)
                        AgentSuggestions(agent: agent)
                    }
                    .padding(10)
                }
            }
            .frame(height: 100)
        }
        .padding(.horizontal, 18).padding(.top, NotchLayout.ear).padding(.bottom, 22)
    }
}
