import SwiftUI

/// Tempo por projeto hoje (assistente, fase 1). Tudo local; privado aparece com cadeado e só o tempo.
struct TodayPage: View {
    @ObservedObject var activity: ActivitySensor
    @ObservedObject var watch: TimerWatch

    var body: some View {
        let rows = Array(activity.today.prefix(4))   // 4 linhas cabem na altura da página
        let total = activity.today.reduce(0) { $0 + $1.seconds }
        let top = max(rows.first?.seconds ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hoje · \(Self.hm(total))").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Button(activity.summaryBusy ? "Resumindo…" : "Resumo") {
                    if activity.summary != nil, !activity.showSummary { activity.showSummary = true } else { activity.makeSummary() }
                }
                .buttonStyle(CapsuleStyle()).disabled(activity.summaryBusy)
                Button(activity.paused ? "Retomar" : "Pausar") { activity.paused.toggle() }.buttonStyle(CapsuleStyle())
            }
            if !activity.trusted {
                HStack(spacing: 8) {
                    Text("Sem a permissão de Acessibilidade, o iLand não vê os projetos.")
                        .font(.system(size: 11)).foregroundColor(.orange).lineLimit(2)
                    Spacer(minLength: 4)
                    // abre direto o painel da Acessibilidade (no macOS 27 se chama "Controle do Dispositivo e Acesso a Dados")
                    Button("Dar permissão") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(CapsuleStyle())
                }
            }
            if let c = watch.card {
                TimerCardView(card: c, watch: watch)
                Spacer(minLength: 0)
            } else if activity.showSummary, let s = activity.summary {
                HStack(alignment: .top, spacing: 6) {
                    Button { activity.showSummary = false } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundColor(.white)
                    ScrollView { Text(Self.inline(s)).font(.system(size: 11)).foregroundColor(.white).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            } else if let r = activity.resume, let at = activity.resumeAt, Date().timeIntervalSince(at) < 900 {
                // Onde parei: nos 15 min depois de voltar ao projeto, o cartão toma o lugar da lista.
                VStack(alignment: .leading, spacing: 4) {
                    Text("↩ \(ProjectResolver.display(r.project)): você parou em").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    ForEach(r.lines, id: \.self) { Text($0).font(.system(size: 11)).foregroundColor(secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            } else {
            if rows.isEmpty {
                Text(activity.paused ? "Pausado: só app e tempo." : "Nada registrado ainda hoje.")
                    .font(.system(size: 11)).foregroundColor(secondary)
            }
            ForEach(rows, id: \.project) { r in
                HStack(spacing: 8) {
                    HStack(spacing: 4) {   // cadeado dentro da coluna do nome: as barras começam todas no mesmo x
                        Text(ProjectResolver.display(r.project)).font(.system(size: 11, weight: .medium)).foregroundColor(.white).lineLimit(1)
                        if r.privateSeconds > 0 { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundColor(secondary) }
                    }
                    .frame(width: 140, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Color.white.opacity(0.25)).frame(width: max(3, g.size.width * r.seconds / top), height: 5)
                            .frame(maxHeight: .infinity)
                    }
                    Text(Self.hm(r.seconds)).font(.system(size: 11)).monospacedDigit().foregroundColor(secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(height: 18)
            }
            Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, NotchLayout.ear)
        .padding(.bottom, 16)
    }

    /// Negrito/itálico do markdown viram estilo (se o Claude mandar mesmo pedindo texto simples); o resto fica como está.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func hm(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m < 60 ? "\(m) min" : "\(m / 60)h\(String(format: "%02d", m % 60))"
    }
}

/// Cartão do vigia do timer (cérebro, fase 1): uma frase e os botões que corrigem direto no ClickUp.
struct TimerCardView: View {
    let card: TimerCard
    @ObservedObject var watch: TimerWatch

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) { buttons }.disabled(watch.busy)
            if !watch.status.isEmpty { Text(watch.status).font(.system(size: 10)).foregroundColor(.orange).lineLimit(2) }
        }
    }

    private var text: String {
        let task = card.entry.taskName
        switch card.kind {
        case .mismatch(let p, let since):
            return "⏱ Timer em “\(task)”, mas você está em \(ProjectResolver.display(p)) desde ~\(Self.hm.string(from: since))."
        case .away(let from, let to):
            let m = Int(to.timeIntervalSince(from) / 60)
            return "⏱ O timer de “\(task)” rodou \(m / 60 > 0 ? "\(m / 60)h\(String(format: "%02d", m % 60))" : "\(m) min") com você longe (\(Self.hm.string(from: from))–\(Self.hm.string(from: to)))."
        case .askProject:
            return "⏱ A task “\(task)” é de qual projeto? (pergunto uma vez)"
        }
    }

    @ViewBuilder private var buttons: some View {
        switch card.kind {
        case .mismatch(_, let since):
            Button("Parar às \(Self.hm.string(from: since))") { watch.act(.stopAt(since)) }.buttonStyle(CapsuleStyle(tint: .orange))
            Button("Parar agora") { watch.act(.stopNow) }.buttonStyle(CapsuleStyle())
            Button("Está certo") { watch.act(.itsFine) }.buttonStyle(CapsuleStyle())
            Button("Não vigiar") { watch.act(.ignoreTask) }.buttonStyle(CapsuleStyle())
        case .away(let from, _):
            Button("Descontar") { watch.act(.discount(from: from)) }.buttonStyle(CapsuleStyle(tint: .orange))
            Button("Manter") { watch.act(.keep) }.buttonStyle(CapsuleStyle())
        case .askProject(let options):
            ForEach(options, id: \.self) { p in Button(ProjectResolver.display(p)) { watch.act(.project(p)) }.buttonStyle(CapsuleStyle()) }
            Button("Nenhum") { watch.act(.ignoreTask) }.buttonStyle(CapsuleStyle())
        }
    }
}
