import Foundation

/// Reconhece o arrastar horizontal com 2 dedos no trackpad. Entrada: deslocamento do DEDO (direita positivo).
/// Decide a intenção nos primeiros pontos: horizontal é nosso (página acompanha o dedo); vertical passa para a rolagem da lista.
struct SwipeTracker {
    enum Intent { case undecided, horizontal, vertical }
    private(set) var intent: Intent = .undecided
    /// Quanto o dedo andou na horizontal depois de decidido (a página segue isso).
    private(set) var offset: CGFloat = 0
    /// Quanto o dedo andou na vertical (negativo = dedos para cima) num gesto vertical.
    private(set) var offsetY: CGFloat = 0
    /// O último gesto que terminou foi vertical, para cima, acima do limiar (voltar da visão geral para a vista rápida).
    private(set) var lastWasUp = false
    /// O último gesto foi vertical, para baixo, acima do limiar (entrar no próximo nível).
    private(set) var lastWasDown = false
    var threshold: CGFloat = 60
    var verticalThreshold: CGFloat = 50
    private var ax: CGFloat = 0, ay: CGFloat = 0, sx: CGFloat = 0, sy: CGFloat = 0

    init(threshold: CGFloat = 60) { self.threshold = threshold }

    mutating func begin() { intent = .undecided; offset = 0; offsetY = 0; ax = 0; ay = 0; sx = 0; sy = 0 }

    /// true se o evento é do swipe (horizontal) e deve ser consumido.
    mutating func move(dx: CGFloat, dy: CGFloat) -> Bool {
        if intent == .undecided {
            ax += abs(dx); ay += abs(dy); sx += dx; sy += dy
            if ax + ay > 6 {
                intent = ax > ay * 1.2 ? .horizontal : .vertical
                if intent == .horizontal { offset = sx; return true }
                offsetY = sy
            }
            return false
        }
        guard intent == .horizontal else { offsetY += dy; return false }
        offset += dx
        return true
    }

    /// Fim do gesto: +1 próxima página (dedos para a esquerda), -1 anterior, 0 fica. Zera o estado.
    mutating func end() -> Int {
        let r = intent != .horizontal ? 0 : (offset < -threshold ? 1 : (offset > threshold ? -1 : 0))
        let up = intent == .vertical && offsetY < -verticalThreshold
        let down = intent == .vertical && offsetY > verticalThreshold
        begin()
        lastWasUp = up; lastWasDown = down
        return r
    }

    /// Resistência nas bordas: sem página nessa direção o arrasto rende só 25%.
    static func resisted(_ offset: CGFloat, page: Int, count: Int) -> CGFloat {
        ((page == 0 && offset > 0) || (page == count - 1 && offset < 0)) ? offset * 0.25 : offset
    }
}
