import Foundation

/// Pomodoro como máquina de estados pura (relógio injetado, testável): foco 25 min, pausa 5, pausa longa 15 a cada 4 focos.
struct PomodoroEngine {
    enum Phase: String { case focus, shortBreak, longBreak
        var title: String { switch self { case .focus: "Foco"; case .shortBreak: "Pausa"; case .longBreak: "Pausa longa" } }
    }
    enum State: Equatable { case idle, running(endsAt: Date), paused(remaining: TimeInterval) }

    var focus: TimeInterval = 25 * 60
    var shortBreak: TimeInterval = 5 * 60
    var longBreak: TimeInterval = 15 * 60
    var longEvery = 4
    private(set) var phase: Phase = .focus
    private(set) var state: State = .idle
    private(set) var focusDone = 0

    func duration(_ p: Phase) -> TimeInterval { switch p { case .focus: focus; case .shortBreak: shortBreak; case .longBreak: longBreak } }
    var isRunning: Bool { if case .running = state { return true }; return false }
    var isIdle: Bool { state == .idle }

    /// Tempo que falta na fase atual (nil parado).
    func remaining(now: Date) -> TimeInterval? {
        switch state {
        case .idle: nil
        case .running(let end): max(0, end.timeIntervalSince(now))
        case .paused(let r): r
        }
    }

    mutating func start(now: Date) {
        if case .paused(let r) = state { state = .running(endsAt: now.addingTimeInterval(r)); return }
        state = .running(endsAt: now.addingTimeInterval(duration(phase)))
    }

    mutating func pause(now: Date) {
        if case .running(let end) = state { state = .paused(remaining: max(0, end.timeIntervalSince(now))) }
    }

    mutating func reset() { phase = .focus; state = .idle; focusDone = 0 }

    /// Pula para a próxima fase (sem contar o foco como concluído) e continua rodando.
    mutating func skip(now: Date) { advance(from: phase, completed: false, now: now) }

    /// Chamar a cada segundo. Se a fase acabou, passa para a próxima (rodando) e devolve a que terminou (para avisar).
    mutating func tick(now: Date) -> Phase? {
        guard case .running(let end) = state, now >= end else { return nil }
        let finished = phase
        advance(from: finished, completed: true, now: now)
        return finished
    }

    private mutating func advance(from p: Phase, completed: Bool, now: Date) {
        if p == .focus {
            if completed { focusDone += 1 }
            phase = (completed && focusDone % longEvery == 0) ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        state = .running(endsAt: now.addingTimeInterval(duration(phase)))
    }
}

struct Stopwatch {
    private(set) var accumulated: TimeInterval = 0
    private(set) var startedAt: Date?
    var isRunning: Bool { startedAt != nil }
    var isIdle: Bool { startedAt == nil && accumulated == 0 }

    func elapsed(now: Date) -> TimeInterval { accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0) }
    mutating func start(now: Date) { if startedAt == nil { startedAt = now } }
    mutating func pause(now: Date) { if startedAt != nil { accumulated = elapsed(now: now); startedAt = nil } }
    mutating func reset() { accumulated = 0; startedAt = nil }
}

/// Cafeína: manter o Mac acordado até `endsAt` (distantFuture = sem fim).
struct Caffeine {
    private(set) var endsAt: Date?
    var isOn: Bool { endsAt != nil }

    mutating func turnOn(for duration: TimeInterval?, now: Date) { endsAt = duration.map { now.addingTimeInterval($0) } ?? .distantFuture }
    mutating func turnOff() { endsAt = nil }
    func remaining(now: Date) -> TimeInterval? {
        guard let e = endsAt else { return nil }
        return e == .distantFuture ? .infinity : max(0, e.timeIntervalSince(now))
    }
    /// true se acabou agora (precisa soltar o assertion).
    mutating func expire(now: Date) -> Bool {
        if let e = endsAt, e != .distantFuture, now >= e { endsAt = nil; return true }
        return false
    }
}

enum TimeFmt {
    /// "24:10" (ou "1:02:03" a partir de 1 h).
    static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
    /// Cronômetro com décimos: "00:12.3".
    static func stopwatch(_ s: TimeInterval) -> String {
        let t = max(0, s), m = Int(t) / 60, sec = t - Double(m * 60)
        return String(format: "%02d:%04.1f", m, sec)
    }
}
