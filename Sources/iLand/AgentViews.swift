import SwiftUI

/// Presença do assistente: parado (discreta), pensando (pulsa), tem algo (destaque), pausado (cinza).
struct OrbView: View {
    let state: AgentController.Orb
    var size: CGFloat = 10
    @State private var pulse = false

    var body: some View {
        let color: Color = switch state {
        case .idle: Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.75)
        case .thinking: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .attention: .orange
        case .paused: .gray
        }
        Circle().fill(color)
            .frame(width: size, height: size)
            .scaleEffect(state == .thinking && pulse ? 1.35 : 1)
            .opacity(state == .thinking && pulse ? 0.55 : 1)
            .animation(state == .thinking ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel("Assistente: \(String(describing: state))")
    }
}

/// O que o assistente consultou ("olhei seu dia", "timer do ClickUp").
struct AgentChip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10)).foregroundColor(secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }
}

/// Uma mensagem da conversa: bolha do usuário à direita; do assistente (ou proativa) à esquerda com chips e botões.
struct AgentMessageView: View {
    let message: AgentMessage
    let agent: AgentController
    var compact = false

    var body: some View {
        let isUser = message.role == .user
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: compact ? 20 : 60) }
            else { OrbView(state: message.role == .proactive ? .attention : .idle, size: 8).padding(.top, 5) }
            VStack(alignment: .leading, spacing: 6) {
                if !message.chips.isEmpty {
                    HStack(spacing: 4) { ForEach(message.chips, id: \.self) { AgentChip(text: $0) } }
                }
                if let s = message.state, message.text.isEmpty {
                    Text(s).font(.system(size: compact ? 11 : 13)).foregroundColor(secondary).italic()
                } else {
                    Text(TodayPage.inline(message.text))
                        .font(.system(size: compact ? 11.5 : 13.5)).foregroundColor(.white)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .lineLimit(compact ? 6 : nil)
                }
                if !message.actions.isEmpty {
                    // Depois de clicar, o resultado ("Feito no ClickUp.") toma o lugar dos botões.
                    if let done = message.state { Text("✓ " + done).font(.system(size: 11)).foregroundColor(.green) }
                    else { FlowButtons(actions: message.actions) { agent.act($0, in: message.id) } }
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(isUser ? Color(red: 0.2, green: 0.36, blue: 0.62) : Color.white.opacity(0.08)))
            if !isUser { Spacer(minLength: compact ? 10 : 40) }
        }
    }
}

/// Botões de ação em linha (quebra se não couber).
struct FlowButtons: View {
    let actions: [AgentAction]
    let tap: (AgentAction) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions) { a in
                Button(a.title) { tap(a) }
                    .buttonStyle(CapsuleStyle(tint: a.kind.hasPrefix("proposal.approve") || a.kind == "timer.stopAt" || a.kind == "timer.discount" ? .orange : .white))
                    .lineLimit(1)
            }
        }
    }
}

/// Sugestões prontas acima do campo.
struct AgentSuggestions: View {
    let agent: AgentController
    var project: String?
    var body: some View {
        let items = ["Como foi meu dia?", "O que priorizo agora?"] + (project.map { ["Onde parei no \($0)?"] } ?? [])
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { s in
                Button(s) { agent.send(s) }.buttonStyle(ChipStyle()).disabled(agent.busy)
            }
        }
    }
}
