import SwiftUI

/// Página "Ferramentas" da vista rápida: cafeína, cronômetro, pomodoro e, com token, o timer do ClickUp.
struct ToolsPage: View {
    @ObservedObject var tools: ToolsModel
    @ObservedObject private var ticker: Ticker   // redesenha as contagens a cada segundo
    @ObservedObject private var watch: TimerWatch

    init(tools: ToolsModel) { self.tools = tools; self.ticker = tools.ticker; self.watch = tools.timerWatch }

    var body: some View {
        HStack(spacing: 8) {
            caffeineCard
            stopwatchCard
            pomodoroCard
            if watch.connected { clickupCard }
        }
        .onAppear { watch.refresh() }   // o timer pode ter mudado no ClickUp desde a última leitura (2 min)
        .padding(.horizontal, 18)
        .padding(.top, NotchLayout.ear)
        .padding(.bottom, 22)
    }

    private var caffeineCard: some View {
        let c = tools.caffeine, left = c.remaining(now: tools.now)
        return ToolCard(title: "Cafeína", icon: "cup.and.saucer") {
            if c.isOn {
                Text(left == .infinity ? "sem fim" : TimeFmt.clock(left ?? 0)).font(.system(size: 20, weight: .medium)).monospacedDigit()
                Button("Desligar") { tools.turnOffCaffeine() }.buttonStyle(CapsuleStyle(tint: .orange))
            } else {
                Text("Mac acordado").font(.system(size: 11)).foregroundColor(secondary)
                HStack(spacing: 4) {
                    chip("30m") { tools.turnOnCaffeine(minutes: 30) }
                    chip("1h") { tools.turnOnCaffeine(minutes: 60) }
                    chip("2h") { tools.turnOnCaffeine(minutes: 120) }
                    chip("∞") { tools.turnOnCaffeine(minutes: nil) }
                }
            }
            Button(tools.lidAwake ? "Tampa fechada: ligado" : "Tampa fechada") { tools.toggleLidAwake() }
                .buttonStyle(ChipStyle(tint: tools.lidAwake ? .orange : nil))
                .help("Mantém o Mac acordado com a tampa fechada (pmset disablesleep). Pede a senha de administrador.")
        }
    }

    private var stopwatchCard: some View {
        let w = tools.stopwatch
        return ToolCard(title: "Cronômetro", icon: "stopwatch") {
            Text(TimeFmt.clock(w.elapsed(now: tools.now))).font(.system(size: 20, weight: .medium)).monospacedDigit()
            HStack(spacing: 4) {
                Button(w.isRunning ? "Pausar" : "Iniciar") { tools.toggleStopwatch() }.buttonStyle(CapsuleStyle())
                if !w.isIdle { Button("Zerar") { tools.resetStopwatch() }.buttonStyle(CapsuleStyle(tint: secondary)) }
            }
        }
    }

    private var pomodoroCard: some View {
        let p = tools.pomodoro
        let left = p.remaining(now: tools.now) ?? p.duration(p.phase)
        return ToolCard(title: p.isIdle ? "Pomodoro" : p.phase.title, icon: "timer") {
            Text(TimeFmt.clock(left)).font(.system(size: 20, weight: .medium)).monospacedDigit()
                .foregroundColor(p.phase == .focus ? .white : .green)
            HStack(spacing: 4) {
                Button(p.isRunning ? "Pausar" : "Iniciar") { tools.togglePomodoro() }.buttonStyle(CapsuleStyle())
                if !p.isIdle { Button("Pular") { tools.skipPomodoro() }.buttonStyle(CapsuleStyle(tint: secondary)) }
            }
            if p.focusDone > 0 { Text("\(p.focusDone) foco\(p.focusDone == 1 ? "" : "s")").font(.system(size: 9)).foregroundColor(secondary) }
        }
    }

    private var clickupCard: some View {
        ToolCard(title: "ClickUp", icon: "checklist") {
            if let e = watch.lastEntry {
                Text(TimeFmt.clock(tools.now.timeIntervalSince(e.start))).font(.system(size: 20, weight: .medium)).monospacedDigit()
                taskName(e.taskName)
                Button("Pausar") { watch.pause() }.buttonStyle(CapsuleStyle()).disabled(watch.busy)
            } else if let p = watch.paused {
                Text("Pausada").font(.system(size: 20, weight: .medium)).foregroundColor(secondary)
                taskName(p.taskName)
                Button("Continuar") { watch.resume() }.buttonStyle(CapsuleStyle()).disabled(watch.busy)
            } else {
                Text("Nenhum timer").font(.system(size: 11)).foregroundColor(secondary)
            }
        }
    }

    private func taskName(_ n: String) -> some View {
        Text(n).font(.system(size: 10)).foregroundColor(secondary).lineLimit(1).truncationMode(.tail).help(n)
    }

    private func chip(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(t, action: action).buttonStyle(ChipStyle())
    }
}

struct ToolCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10))
            }
            .foregroundColor(secondary)
            content()
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.09)))
    }
}

/// Botão pequeno de uma linha só (as durações da cafeína: 30m, 1h, 2h, ∞).
struct ChipStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1).fixedSize()
            .foregroundColor(tint == nil ? .white : .black)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(tint ?? Color.white.opacity(configuration.isPressed ? 0.28 : 0.14)))
    }
}
