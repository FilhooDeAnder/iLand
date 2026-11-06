import SwiftUI

/// Barra de ícones das páginas da vista rápida. Quando os ícones não cabem, ela rola na horizontal: com o mouse perto de uma
/// ponta ela desliza para aquele lado (mais rápido quanto mais perto da ponta). A engrenagem fica fora da área que rola.
struct PageBar: View {
    @ObservedObject var model: NotchUIModel
    let width: CGFloat

    static let pitch: CGFloat = 32          // ícone de 30 pt + 2 pt de espaço
    static let zone: CGFloat = 36           // faixa em cada ponta onde o mouse faz a barra rolar
    static let maxSpeed: CGFloat = 260      // pt/s, na ponta
    static let fade: CGFloat = 18
    private let gearArea: CGFloat = 1 + 8 + 30   // separador (com margens) + engrenagem
    private let margin = NotchLayout.ear

    @State private var scrollX: CGFloat = 0
    @State private var velocity: CGFloat = 0
    @State private var ticker: Timer?
    @State private var limit: CGFloat = 0     // maxX atual, para o timer não usar uma cópia velha
    @State private var track = Track()

    /// Só o movimento real do mouse libera o hover: ícones que mudam de lugar sob o mouse parado (reveal, rolagem) não trocam a página.
    private final class Track { var last: CGPoint?; var real = false }

    private var pages: [QuickPage] { model.visiblePages.compactMap(QuickPage.init(rawValue:)) }
    private var contentWidth: CGFloat { CGFloat(pages.count) * Self.pitch - 2 }
    private var viewport: CGFloat { min(contentWidth, width - 2 * margin - gearArea) }
    private var maxX: CGFloat { max(0, contentWidth - viewport) }

    var body: some View {
        let list = pages
        let maxX = maxX, x = min(scrollX, maxX)
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                HStack(spacing: 2) { ForEach(list, id: \.rawValue) { icon($0) } }
                    .fixedSize()
                    .offset(x: -x)
            }
            .frame(width: viewport, height: 20, alignment: .leading)
            .clipped()
            .mask(fadeMask(left: x > 1, right: x < maxX - 1))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    if p != track.last { track.last = p; track.real = true }
                    setVelocity(at: p.x)
                case .ended: setVelocity(0)
                }
            }
            Rectangle().fill(secondary.opacity(0.4)).frame(width: 1, height: 12).padding(.horizontal, 4)
            // Ajustes já na aba da página atual (ex.: Máquinas abre o cadastro de máquinas).
            let page = QuickPage(rawValue: model.quickPage) ?? .summary
            Button { SettingsWindow.shared.show(page.settingsTab) } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondary).frame(width: 30, height: 20).contentShape(Capsule())
            }
            .buttonStyle(.plain).help("Ajustes · \(page.settingsTab.rawValue)")
        }
        .frame(width: width)
        .onAppear { limit = maxX; reveal(animated: false) }
        .onChange(of: model.quickPage) { _ in reveal(animated: true) }
        .onChange(of: list.count) { _ in limit = self.maxX; scrollX = min(scrollX, limit); reveal(animated: false) }
        .onChange(of: width) { _ in limit = self.maxX; scrollX = min(scrollX, limit) }
        .onChange(of: model.mode) { if $0 != .quick { setVelocity(0) } }
        .onDisappear { setVelocity(0) }
    }

    private func icon(_ p: QuickPage) -> some View {
        let on = p.rawValue == model.quickPage
        return Button { model.selectPage(p.rawValue) } label: {
            Image(systemName: p.symbol).font(.system(size: 11, weight: .medium))
                .foregroundColor(on ? .white : secondary)
                .frame(width: 30, height: 20)
                .background(Capsule().fill(Color.white.opacity(on ? 0.2 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(p.title)
        // Com a barra deslizando os ícones passam sob o mouse parado: só vale o hover com ela parada.
        .onHover { if $0, !on, velocity == 0, track.real { model.selectPage(p.rawValue) } }
    }

    private func fadeMask(left: Bool, right: Bool) -> some View {
        let f = min(0.5, Self.fade / max(viewport, 1))
        return LinearGradient(stops: [
            .init(color: left ? .clear : .black, location: 0), .init(color: .black, location: f),
            .init(color: .black, location: 1 - f), .init(color: right ? .clear : .black, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
        .animation(.easeOut(duration: 0.15), value: left)
        .animation(.easeOut(duration: 0.15), value: right)
    }

    /// Velocidade pela posição do mouse na área que rola: 0 no meio, cresce (ao quadrado) até a ponta.
    private func setVelocity(at x: CGFloat) {
        guard maxX > 0 else { return setVelocity(0) }
        let t: CGFloat
        if x < Self.zone { t = -((Self.zone - max(x, 0)) / Self.zone) }
        else if x > viewport - Self.zone { t = (min(x, viewport) - (viewport - Self.zone)) / Self.zone }
        else { t = 0 }
        setVelocity(t * abs(t) * Self.maxSpeed)
    }

    private func setVelocity(_ v: CGFloat) {
        velocity = v
        if v == 0 { ticker?.invalidate(); ticker = nil; return }
        track.real = false   // começou a deslizar: o hover só volta com um movimento novo
        guard ticker == nil else { return }
        var last = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            let now = Date(), dt = CGFloat(now.timeIntervalSince(last)); last = now
            let next = min(max(scrollX + velocity * dt, 0), limit)
            scrollX = next
            if next == 0 && velocity < 0 || next == limit && velocity > 0 { setVelocity(0); track.real = false }
        }
    }

    /// Rola o mínimo para o ícone da página atual ficar inteiro à vista (com folga para ver o vizinho).
    private func reveal(animated: Bool) {
        guard let i = pages.firstIndex(where: { $0.rawValue == model.quickPage }) else { return }
        let left = CGFloat(i) * Self.pitch, right = left + 30
        var target = scrollX
        if left < scrollX { target = left - margin } else if right > scrollX + viewport { target = right - viewport + margin }
        target = min(max(target, 0), maxX)
        guard target != scrollX else { return }
        track.real = false
        if animated { withAnimation(.easeOut(duration: 0.25 * NotchLayout.slow)) { scrollX = target } } else { scrollX = target }
    }
}
