import AppKit
import SwiftUI

/// Medidas reais do notch, lidas do macOS (nada de pixel calibrado à mão).
/// Com "Mostrar nas outras telas" ligado, cada tela sem notch ganha um notch desenhado (FakeNotches) com a largura
/// do notch real e a altura da barra de menus daquela tela. A ilha abre na tela do mouse (`activeScreen`).
struct NotchGeometry {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat

    /// Tela onde a ilha está (ou abriu por último). Muda só quando ela abre a partir do repouso.
    static var activeScreen: CGDirectDisplayID?

    static func id(_ s: NSScreen) -> CGDirectDisplayID? { s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
    var id: CGDirectDisplayID? { Self.id(screen) }

    private static func real(_ s: NSScreen) -> NotchGeometry? {
        guard s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
        return NotchGeometry(screen: s, width: r.minX - l.maxX, height: s.safeAreaInsets.top)
    }

    /// Todas as telas onde a ilha pode abrir: as com notch e, se a opção estiver ligada, as outras com o notch desenhado.
    static func all() -> [NotchGeometry] {
        let screens = NSScreen.screens
        let reals = screens.compactMap(real)
        guard Prefs.bool(Prefs.Key.otherScreens) else { return reals }
        let w = reals.first?.width ?? 200
        return screens.map { s in
            real(s) ?? NotchGeometry(screen: s, width: w, height: s.frame.maxY - s.visibleFrame.maxY > 0
                                     ? s.frame.maxY - s.visibleFrame.maxY : reals.first?.height ?? NSStatusBar.system.thickness)
        }
    }

    /// A ilha na tela ativa; sem ela, a do notch real; sem notch real (tampa fechada), a primeira desenhada.
    static func current() -> NotchGeometry? {
        let a = all()
        return a.first { $0.id == activeScreen } ?? a.first { $0.screen.safeAreaInsets.top > 0 } ?? a.first
    }

    /// Notch (real ou desenhado) embaixo do ponto.
    static func at(_ p: NSPoint) -> NotchGeometry? { all().first { $0.hoverZone.contains(p) } }

    /// Antes de abrir a partir do repouso: a ilha vai para a tela do mouse, se ela tiver notch (real ou desenhado).
    static func follow(_ p: NSPoint) {
        // Depuração: ILAND_SCREEN=1 abre sempre na 2ª tela, sem mexer no mouse.
        if let i = ProcessInfo.processInfo.environment["ILAND_SCREEN"].flatMap(Int.init), let s = NSScreen.screens.dropFirst(i).first { activeScreen = id(s); return }
        if let g = all().first(where: { $0.screen.frame.contains(p) }) { activeScreen = g.id }
    }

    var centerX: CGFloat { screen.frame.midX }
    var top: CGFloat { screen.frame.maxY }

    /// Área do mouse que conta como "em cima do notch".
    var hoverZone: NSRect {
        NSRect(x: centerX - width / 2 - 12, y: top - height - 2, width: width + 24, height: height + 4)
    }
}

/// O notch desenhado nas telas sem notch: uma peça preta parada no topo, embaixo da janela da ilha.
/// Tem o mesmo formato das orelhas fechadas (cantos côncavos em cima, arredondados embaixo), então a ilha sai dela.
final class FakeNotches {
    private var panels: [NSPanel] = []
    private var last = ""

    init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let fakes = NotchGeometry.all().filter { $0.screen.safeAreaInsets.top == 0 }
        let key = fakes.map { "\($0.screen.frame)\($0.width)\($0.height)" }.joined()
        guard key != last else { return }   // UserDefaults avisa a cada mudança de qualquer chave
        last = key
        panels.forEach { $0.orderOut(nil) }
        panels = fakes.map { g in
            let ear = NotchLayout.ear, w = g.width + 2 * ear
            let p = NSPanel(contentRect: NSRect(x: g.centerX - w / 2, y: g.top - g.height, width: w, height: g.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: IslandShape(topWidth: w, bodyWidth: g.width, height: g.height, radius: ear, shoulder: g.height).fill(Color.black))
            p.orderFrontRegardless()
            return p
        }
    }
}
