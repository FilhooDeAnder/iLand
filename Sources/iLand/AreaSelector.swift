import AppKit

/// Seleção de área própria (mira, tamanho ao vivo, Esc cancela, Espaço move a seleção).
/// Devolve o retângulo em pontos, origem no canto superior esquerdo da tela principal (o formato do `screencapture -R`).
final class AreaSelector {
    private static var current: AreaSelector?
    private var windows: [SelectorWindow] = []
    private var done: ((CGRect?) -> Void)?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    static func pick(_ completion: @escaping (CGRect?) -> Void) {
        guard current == nil else { return }
        let selector = AreaSelector()
        current = selector
        selector.done = completion
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let w = SelectorWindow(screen: screen) { [weak selector] rect in selector?.finish(rect) }
            selector.windows.append(w)
            w.makeKeyAndOrderFront(nil)
        }
        NSCursor.crosshair.push()
        // Esc cancela mesmo se outro app estiver com o foco. Se outro app tomar o foco depois de um instante, cancela também.
        selector.keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak selector] e in if e.keyCode == 53 { selector?.finish(nil) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak selector] in
            guard let selector, selector.done != nil else { return }
            selector.resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak selector] _ in selector?.finish(nil) }
        }
    }

    private func finish(_ rect: CGRect?) {
        guard done != nil else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil; resignObserver = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let callback = done; done = nil
        Self.current = nil
        // O macOS leva um instante para tirar a camada escura da tela; sem isso ela aparece no print.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let rect else { return callback?(nil) ?? () }
            let top = NSScreen.screens[0].frame.maxY
            callback?(CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height))
        }
    }
}

private final class SelectorWindow: NSPanel {
    init(screen: NSScreen, onFinish: @escaping (CGRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver; isOpaque = false; backgroundColor = .clear; hasShadow = false
        isReleasedWhenClosed = false; ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = SelectorView(frame: NSRect(origin: .zero, size: screen.frame.size), onFinish: onFinish)
        setFrame(screen.frame, display: true)
    }
    override var canBecomeKey: Bool { true }
}

private final class SelectorView: NSView {
    private let onFinish: (CGRect?) -> Void
    private var start: NSPoint?, current: NSPoint?, mouse: NSPoint = .zero
    private var moving = false, moveAnchor: NSPoint = .zero

    init(frame: NSRect, onFinish: @escaping (CGRect?) -> Void) {
        self.onFinish = onFinish
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self); window?.acceptsMouseMovedEvents = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let a = start, let b = current else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let s = selection { dim.appendRect(s); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.3).setFill(); dim.fill()
        guard let s = selection else { drawGuides(); return }
        NSColor.white.setStroke()
        let frame = NSBezierPath(rect: s.insetBy(dx: 0.5, dy: 0.5)); frame.lineWidth = 1; frame.stroke()
        drawLabel("\(Int(s.width)) × \(Int(s.height))", near: s)
    }

    /// Antes de arrastar: linhas finas até as bordas e as coordenadas, como a mira do Shottr.
    private func drawGuides() {
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1
        path.move(to: NSPoint(x: 0, y: mouse.y)); path.line(to: NSPoint(x: bounds.maxX, y: mouse.y))
        path.move(to: NSPoint(x: mouse.x, y: 0)); path.line(to: NSPoint(x: mouse.x, y: bounds.maxY)); path.stroke()
    }

    private func drawLabel(_ text: String, near rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = NSRect(x: min(max(4, rect.midX - size.width / 2 - 8), bounds.maxX - size.width - 20), y: rect.minY - size.height - 14 < 4 ? rect.maxY + 6 : rect.minY - size.height - 12, width: size.width + 16, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: attrs)
    }

    override func mouseMoved(with event: NSEvent) { mouse = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if moving, let a = start, let b = current {
            let d = NSSize(width: p.x - moveAnchor.x, height: p.y - moveAnchor.y)
            start = NSPoint(x: a.x + d.width, y: a.y + d.height); current = NSPoint(x: b.x + d.width, y: b.y + d.height); moveAnchor = p
        } else { current = p }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let s = selection, s.width >= 3, s.height >= 3, let window else { start = nil; current = nil; needsDisplay = true; return }
        onFinish(s.offsetBy(dx: window.frame.minX, dy: window.frame.minY))
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish(nil)
        case 49: moving = true; moveAnchor = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { moving = false } }
    override func rightMouseDown(with event: NSEvent) { onFinish(nil) }
}
