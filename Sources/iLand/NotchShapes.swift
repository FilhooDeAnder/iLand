import SwiftUI

enum NotchLayout {
    static let ear: CGFloat = 14
    static let wing: CGFloat = 76
    static let quickWidth: CGFloat = 480
    static let overviewWidth: CGFloat = 560
    static let overviewHeight: CGFloat = 428
    static let fillet: CGFloat = 16
    /// Distância do topo da janela da visão geral até a lista da aba (abaixo do cabeçalho, dos cartões e das abas).
    static let overviewListTop: CGFloat = 215
    /// ILAND_SLOW=1 deixa as animações 8x mais lentas, para conferir quadro a quadro em screenshots.
    static let slow: Double = ProcessInfo.processInfo.environment["ILAND_SLOW"] != nil ? 8 : 1

    /// Tela de desenho fixa, presa ao topo da tela e centrada no notch: cabe qualquer estado.
    static func canvas(notchHeight nh: CGFloat) -> CGSize {
        CGSize(width: overviewWidth, height: max(nh + overviewHeight, quickHeight(notchHeight: nh, suspects: 3, alerts: 2)))
    }

    /// Barra de ícones das páginas, no topo da vista rápida (abaixo do cabeçalho).
    static let navBar: CGFloat = 20

    /// Página Ferramentas da vista rápida: cartões de 112 pt entre 14 pt de cima e 22 pt de baixo.
    static func toolsHeight(notchHeight: CGFloat) -> CGFloat { notchHeight + 14 + 112 + 22 }

    /// Página Claude: campo (30) + espaço (8) + resposta (100) entre 14 de cima e 22 de baixo.
    static func claudeHeight(notchHeight: CGFloat) -> CGFloat { notchHeight + 14 + 138 + 22 }

    /// Página Área de transferência: pesquisa (32) + lista (104).
    static func clipboardHeight(notchHeight: CGFloat) -> CGFloat { notchHeight + 14 + 142 + 22 }

    /// Página Atalhos: grade 2x3 (98) + mensagem (20).
    static func shortcutsHeight(notchHeight: CGFloat) -> CGFloat { notchHeight + 14 + 118 + 22 }

    /// Página Máquinas: 4 linhas de 44 pt, o resto rola (ou o detalhe de uma máquina, na mesma altura). Hoje usa 3.
    static func machinesHeight(notchHeight: CGFloat, rows: Int = 4) -> CGFloat { notchHeight + 14 + CGFloat(rows) * 44 + 22 }

    /// Altura da vista rápida na página `page` (a primeira varia com suspeitos e alertas; as outras são fixas).
    static func pageHeight(_ page: Int, notchHeight nh: CGFloat, suspects: Int, alerts: Int) -> CGFloat {
        let h: CGFloat = switch page {
        case QuickPage.summary.rawValue: quickHeight(notchHeight: nh, suspects: suspects, alerts: alerts)
        case QuickPage.claude.rawValue, QuickPage.notes.rawValue: claudeHeight(notchHeight: nh)
        case QuickPage.shortcuts.rawValue: shortcutsHeight(notchHeight: nh)
        case QuickPage.capture.rawValue: shortcutsHeight(notchHeight: nh) + 8
        case QuickPage.clipboard.rawValue: clipboardHeight(notchHeight: nh)
        case QuickPage.machines.rawValue: machinesHeight(notchHeight: nh)
        case QuickPage.today.rawValue: machinesHeight(notchHeight: nh, rows: 3)
        default: toolsHeight(notchHeight: nh)
        }
        return navBar + h
    }

    /// Maior altura que qualquer página da vista rápida pode ter.
    static func maxQuickHeight(notchHeight nh: CGFloat) -> CGFloat {
        navBar + max(quickHeight(notchHeight: nh, suspects: 3, alerts: 2), claudeHeight(notchHeight: nh), clipboardHeight(notchHeight: nh), machinesHeight(notchHeight: nh))
    }

    /// Vista rápida: até 3 suspeitos (84 pt cada) e até 2 alertas (48 pt cada).
    static func quickHeight(notchHeight: CGFloat, suspects n: Int, alerts a: Int = 0) -> CGFloat {
        notchHeight + (n + a == 0 ? 34 : CGFloat(n) * 84 + CGFloat(a) * 48) + 10 + 28 + 16
    }
}

/// A silhueta inteira da peça do notch como UMA forma preta, em coordenadas da tela (y = 0 no topo).
/// Topo mais largo que o corpo (repouso, orelhas, vista rápida): curvas côncavas que fundem na borda da tela.
/// Corpo mais largo que o topo (visão geral): o topo vira o "pescoço" do notch e o corpo pende da base dele
/// (`shoulder`), ligado por curvas côncavas. Quando as larguras se igualam as curvas valem 0 nos dois casos,
/// então o morph entre eles é contínuo. Quem anima as medidas é o IslandFrame.
struct IslandShape: Shape {
    var topWidth: CGFloat
    var bodyWidth: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var shoulder: CGFloat

    func path(in r: CGRect) -> Path {
        let a = topWidth / 2, b = bodyWidth / 2, h = height
        // Perfil do lado direito, de cima para baixo: (ponto, controle da curva; nil = reta).
        var seg: [(CGPoint, CGPoint?)] = []
        let bodyTop: CGFloat
        if b <= a {
            seg.append((CGPoint(x: b, y: a - b), CGPoint(x: b, y: 0)))
            bodyTop = a - b
        } else {
            let d = b - a, ys = min(shoulder, h)
            let f = min(NotchLayout.fillet, d / 2, ys)
            let rt = max(0, min(20, d - f, (h - ys) / 2))
            seg += [(CGPoint(x: a, y: ys - f), nil), (CGPoint(x: a + f, y: ys), CGPoint(x: a, y: ys)),
                    (CGPoint(x: b - rt, y: ys), nil), (CGPoint(x: b, y: ys + rt), CGPoint(x: b, y: ys))]
            bodyTop = ys + rt
        }
        let rb = max(0, min(radius, b, h - bodyTop))
        seg += [(CGPoint(x: b, y: h - rb), nil), (CGPoint(x: b - rb, y: h), CGPoint(x: b, y: h))]

        let pts = [CGPoint(x: a, y: 0)] + seg.map(\.0)
        func right(_ q: CGPoint) -> CGPoint { CGPoint(x: r.midX + q.x, y: r.minY + q.y) }
        func left(_ q: CGPoint) -> CGPoint { CGPoint(x: r.midX - q.x, y: r.minY + q.y) }
        var p = Path()
        p.move(to: right(pts[0]))
        for (q, c) in seg {
            if let c { p.addQuadCurve(to: right(q), control: right(c)) } else { p.addLine(to: right(q)) }
        }
        p.addLine(to: left(pts[pts.count - 1]))
        for i in seg.indices.reversed() {
            if let c = seg[i].1 { p.addQuadCurve(to: left(pts[i]), control: left(c)) } else { p.addLine(to: left(pts[i])) }
        }
        p.closeSubpath()
        return p
    }
}
