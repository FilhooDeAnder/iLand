import AppKit
import SwiftUI
import UserNotifications

/// Aviso rápido e discreto no topo da tela ("Copiado"). O estilo vem dos ajustes: custom, system ou none.
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, seconds: Double = 1.8) {
        switch CapturePrefs.string(CapturePrefs.Key.confirm) {
        case "none": return
        case "system": system(text)
        default: custom(text, seconds)
        }
    }

    private static func system(_ text: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent(); content.title = "iLand"; content.body = text
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func custom(_ text: String, _ seconds: Double) {
        let host = NSHostingView(rootView: Text(text).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.black.opacity(0.82))).environment(\.colorScheme, .dark))
        let size = host.fittingSize
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .statusBar; p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel = p
        }
        guard let p = panel else { return }
        p.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame { p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 24, width: size.width, height: size.height), display: true) }
        p.alphaValue = 1; p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) }) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
