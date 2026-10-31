import AppKit

/// Medidas reais do notch, lidas do macOS (nada de pixel calibrado à mão).
struct NotchGeometry {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat

    static func current() -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return NotchGeometry(screen: screen, width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }

    var centerX: CGFloat { screen.frame.midX }
    var top: CGFloat { screen.frame.maxY }

    /// Área do mouse que conta como "em cima do notch".
    var hoverZone: NSRect {
        NSRect(x: centerX - width / 2 - 12, y: top - height - 2, width: width + 24, height: height + 4)
    }
}
