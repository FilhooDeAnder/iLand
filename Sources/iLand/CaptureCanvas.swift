import AppKit

/// Um objeto desenhado sobre a captura. Coordenadas em pixels da imagem, origem embaixo à esquerda.
struct Annotation {
    var tool: CaptureEditorCanvas.Tool
    var a: NSPoint
    var b: NSPoint
    var path: [NSPoint] = []
    var color: NSColor
    var width: CGFloat
    var text = ""
    var number = 0
    var fill = false
    var dashed = false
    var opacity: CGFloat = 1
    var arrowStyle = ArrowStyle.open
    var picture: CGImage?   // captura adicionada (ferramenta .picture)
    enum ArrowStyle: Int { case open, filled, double }

    var rect: NSRect { NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
    var fontSize: CGFloat { width * 4 + 8 }
    var counterRadius: CGFloat { width * 3.5 }
    var textOrigin: NSPoint { NSPoint(x: a.x, y: a.y - textSize.height) }
    var textSize: NSSize { (text as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: fontSize)]) }

    var bounds: NSRect {
        switch tool {
        case .text: return NSRect(origin: textOrigin, size: textSize)
        case .counter: return NSRect(x: a.x - counterRadius, y: a.y - counterRadius, width: counterRadius * 2, height: counterRadius * 2)
        case .freehand:
            let xs = path.map(\.x), ys = path.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -width, dy: -width)
        default: return rect.insetBy(dx: -width, dy: -width)
        }
    }

    mutating func move(by d: NSSize) {
        a.x += d.width; a.y += d.height; b.x += d.width; b.y += d.height
        path = path.map { NSPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }

    /// Desenha o objeto em `cg` (espaço da imagem). Ocultar e lupa precisam da imagem por baixo: ficam em `CaptureEditorCanvas.render`.
    func draw(in cg: CGContext, canvas: CGSize) {
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        cg.saveGState(); cg.setAlpha(opacity)
        defer { cg.restoreGState(); NSGraphicsContext.current = saved }
        let line = NSBezierPath()
        line.lineWidth = width; line.lineCapStyle = .round; line.lineJoinStyle = .round
        if dashed { line.setLineDash([width * 2.2, width * 1.6], count: 2, phase: 0) }
        color.setStroke()
        switch tool {
        case .arrow:
            line.move(to: a); line.line(to: b); line.stroke()
            let head = width * 4.5
            func tip(_ p: NSPoint, _ q: NSPoint) {
                let angle = atan2(p.y - q.y, p.x - q.x)
                let left = NSPoint(x: p.x - head * cos(angle - .pi / 6), y: p.y - head * sin(angle - .pi / 6))
                let right = NSPoint(x: p.x - head * cos(angle + .pi / 6), y: p.y - head * sin(angle + .pi / 6))
                let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.move(to: left); path.line(to: p); path.line(to: right)
                if arrowStyle == .filled { path.close(); color.setFill(); path.fill() }
                path.stroke()
            }
            tip(b, a)
            if arrowStyle == .double { tip(a, b) }
        case .line: line.move(to: a); line.line(to: b); line.stroke()
        case .rectangle: line.appendRect(rect); if fill { color.setFill(); line.fill() }; line.stroke()
        case .oval: line.appendOval(in: rect); if fill { color.setFill(); line.fill() }; line.stroke()
        case .spotlight:
            let dim = NSBezierPath(rect: NSRect(origin: .zero, size: canvas)); dim.appendRect(rect); dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill(); dim.fill()
        case .ruler:
            line.move(to: a); line.line(to: b); line.stroke()
            let ticks = NSBezierPath(); ticks.lineWidth = width; ticks.lineCapStyle = .round
            let angle = atan2(b.y - a.y, b.x - a.x) + .pi / 2, t = width * 3
            for p in [a, b] { ticks.move(to: NSPoint(x: p.x - t * cos(angle), y: p.y - t * sin(angle))); ticks.line(to: NSPoint(x: p.x + t * cos(angle), y: p.y + t * sin(angle))) }
            ticks.stroke()
            let label = "\(Int(hypot(b.x - a.x, b.y - a.y).rounded())) px" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: width * 3 + 8, weight: .semibold), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attrs)
            let pill = NSRect(x: (a.x + b.x) / 2 - size.width / 2 - 6, y: (a.y + b.y) / 2 + width * 2, width: size.width + 12, height: size.height + 4)
            color.setFill(); NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
        case .freehand:
            guard let first = path.first else { return }
            line.move(to: first); path.dropFirst().forEach { line.line(to: $0) }; line.stroke()
        case .highlight: color.withAlphaComponent(0.4).setFill(); rect.fill()
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: color]
            (text as NSString).draw(at: textOrigin, withAttributes: attrs)
        case .counter:
            color.setFill(); NSBezierPath(ovalIn: bounds).fill()
            let label = "\(number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: counterRadius * 1.15), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: a.x - size.width / 2, y: a.y - size.height / 2), withAttributes: attrs)
        case .picture: if let picture { cg.draw(picture, in: rect) }
        case .blur, .magnifier, .select, .crop: break
        }
    }
}

/// Área de edição: imagem base + objetos. `image` é sempre a composição final (o que copiar, salvar e enviar).
final class CaptureEditorCanvas: NSView, NSTextFieldDelegate {
    enum Tool: CaseIterable { case select, arrow, line, rectangle, oval, freehand, text, highlight, blur, spotlight, magnifier, ruler, counter, crop, picture }

    private struct State { var base: CGImage; var annotations: [Annotation] }

    private var base: CGImage
    private(set) var annotations: [Annotation] = []
    private(set) var image: NSImage
    private(set) var dirty = false
    private var undoStack: [State] = [], redoStack: [State] = []
    private var draft: Annotation?
    private var selected: Int?
    private var dragLast: NSPoint?
    private var dragSnapshotTaken = false
    private var resizing = false
    private var editingField: NSTextField?
    private var editingOrigin = NSPoint.zero

    var tool: Tool = .arrow { didSet { selected = nil; commitText(); color = colors[tool] ?? color; onChange?(); needsDisplay = true } }
    var colors: [Tool: NSColor] = [.highlight: .systemYellow, .blur: .black]
    var color = NSColor.systemRed { didSet { colors[tool] = color; if let i = selected { annotations[i].color = color; rerender() } } }
    var sizeSetting: CGFloat = 4
    var fill = false { didSet { restyleSelected { $0.fill = fill } } }
    var dashed = false { didSet { restyleSelected { $0.dashed = dashed } } }
    var opacity: CGFloat = 1 { didSet { restyleSelected { $0.opacity = opacity } } }
    var arrowStyle = Annotation.ArrowStyle.open { didSet { restyleSelected { $0.arrowStyle = arrowStyle } } }
    private func restyleSelected(_ change: (inout Annotation) -> Void) {
        guard let i = selected, annotations.indices.contains(i) else { return }
        pushUndo(); change(&annotations[i]); rerender()
    }
    /// nil = ajustar à janela; senão, escala em pontos da vista por pixel da imagem.
    var zoom: CGFloat? { didSet { updateFrame(); needsDisplay = true; onChange?() } }
    var onChange: (() -> Void)?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Tamanho final em pixels (com o fundo, se ligado).
    var pixelSize: (Int, Int) { (Int(displaySize.width), Int(displaySize.height)) }
    private(set) var displaySize: CGSize
    private(set) var contentOffset = CGPoint.zero
    var backdrop = Backdrop() { didSet { if backdrop != oldValue { dirty = true; rerender(); updateFrame() } } }

    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        base = cg
        displaySize = CGSize(width: cg.width, height: cg.height)
        self.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    // MARK: composição

    private static func render(_ base: CGImage, _ annotations: [Annotation]) -> CGImage {
        guard let cg = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        cg.draw(base, in: full)
        for note in annotations {
            if note.tool == .blur {
                let r = note.rect.integral.intersection(full)
                guard r.width >= 1, r.height >= 1, let now = cg.makeImage() else { continue }
                // Average into a small bitmap, then enlarge without interpolation. This
                // works without a Core Image render device (including headless runs).
                let block = max(8, note.width * 3)
                let source = CGRect(x: r.minX, y: full.height - r.maxY, width: r.width, height: r.height)
                guard let piece = now.cropping(to: source),
                      let small = CGContext(data: nil, width: max(1, Int(ceil(r.width / block))),
                                            height: max(1, Int(ceil(r.height / block))),
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                small.interpolationQuality = .high
                small.draw(piece, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
                if let out = small.makeImage() {
                    cg.saveGState()
                    cg.interpolationQuality = .none
                    cg.draw(out, in: r)
                    cg.restoreGState()
                }
            } else if note.tool == .magnifier {
                let r = note.rect.intersection(full), side = min(r.width, r.height)
                guard side >= 8, let now = cg.makeImage() else { continue }
                let lens = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
                let src = CGRect(x: lens.midX - side / 4, y: lens.midY - side / 4, width: side / 2, height: side / 2)   // 2×
                if let piece = now.cropping(to: CGRect(x: src.minX, y: CGFloat(now.height) - src.maxY, width: src.width, height: src.height)) {
                    cg.saveGState(); cg.addEllipse(in: lens); cg.clip(); cg.interpolationQuality = .high; cg.draw(piece, in: lens); cg.restoreGState()
                }
                cg.setStrokeColor(note.color.cgColor); cg.setLineWidth(note.width); cg.strokeEllipse(in: lens.insetBy(dx: note.width / 2, dy: note.width / 2))
            } else { note.draw(in: cg, canvas: CGSize(width: base.width, height: base.height)) }
        }
        return cg.makeImage() ?? base
    }

    private func rerender() {
        let inner = Self.render(base, annotations)
        let final = backdrop.render(inner)
        let layout = backdrop.layout(for: CGSize(width: inner.width, height: inner.height))
        displaySize = layout.size; contentOffset = layout.offset
        image = NSImage(cgImage: final, size: NSSize(width: final.width, height: final.height))
        needsDisplay = true
        onChange?()
    }

    // MARK: edição

    private func pushUndo() {
        undoStack.append(State(base: base, annotations: annotations))
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll(); dirty = true
    }

    func add(_ note: Annotation) { pushUndo(); annotations.append(note); selected = nil; rerender() }

    /// O contador novo continua a numeração dos que já existem.
    func makeAnnotation(_ tool: Tool, from a: NSPoint, to b: NSPoint) -> Annotation {
        let unit = max(1, CGFloat(base.width) / 700)
        return Annotation(tool: tool, a: a, b: b, path: [a], color: color, width: sizeSetting * unit,
                          number: (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1,
                          fill: fill, dashed: dashed, opacity: tool == .highlight || tool == .spotlight || tool == .blur ? 1 : opacity, arrowStyle: arrowStyle)
    }

    /// Corta a composição atual. `rect` em pixels da imagem, origem embaixo à esquerda.
    func crop(to rect: NSRect) {
        let r = rect.integral.intersection(NSRect(x: 0, y: 0, width: base.width, height: base.height))
        guard r.width >= 1, r.height >= 1,
              case let flat = Self.render(base, annotations),
              let cropped = flat.cropping(to: CGRect(x: r.minX, y: CGFloat(base.height) - r.maxY, width: r.width, height: r.height)) else { return }
        pushUndo(); base = cropped; annotations = []; selected = nil; rerender(); updateFrame()
    }

    /// Põe uma captura nova em cima da imagem (como o "Adicionar captura" do Shottr). Cabe em 70% da imagem e dá para mover e redimensionar.
    func addPicture(_ cg: CGImage) {
        let maxW = CGFloat(base.width) * 0.7, maxH = CGFloat(base.height) * 0.7
        let k = min(1, maxW / CGFloat(cg.width), maxH / CGFloat(cg.height))
        let w = CGFloat(cg.width) * k, h = CGFloat(cg.height) * k
        let origin = NSPoint(x: (CGFloat(base.width) - w) / 2, y: (CGFloat(base.height) - h) / 2)
        var note = makeAnnotation(.picture, from: origin, to: NSPoint(x: origin.x + w, y: origin.y + h))
        note.picture = cg
        add(note)
        selected = annotations.count - 1
        needsDisplay = true
    }

    func deleteSelected() { guard let i = selected else { return }; pushUndo(); annotations.remove(at: i); selected = nil; rerender() }
    func markApplied() { dirty = false }

    func undoEdit() { step(from: &undoStack, to: &redoStack) }
    func redoEdit() { step(from: &redoStack, to: &undoStack) }
    private func step(from source: inout [State], to target: inout [State]) {
        guard let state = source.popLast() else { return }
        target.append(State(base: base, annotations: annotations))
        base = state.base; annotations = state.annotations; selected = nil; dirty = true
        rerender(); updateFrame()
    }

    // MARK: geometria

    override var acceptsFirstResponder: Bool { true }
    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }
    var actualScale: CGFloat { 1 / backing }
    private var viewport: NSSize { enclosingScrollView?.contentSize ?? bounds.size }
    var scale: CGFloat {
        if let zoom { return zoom }
        let v = viewport, fit = min((v.width - 48) / displaySize.width, (v.height - 48) / displaySize.height)
        return max(0.05, min(actualScale, fit))
    }
    func updateFrame() {
        let v = viewport, s = scale
        setFrameSize(NSSize(width: max(v.width, displaySize.width * s + 48), height: max(v.height, displaySize.height * s + 48)))
    }
    override func viewDidMoveToWindow() { updateFrame() }
    private var imageRect: NSRect {
        let s = scale, w = displaySize.width * s, h = displaySize.height * s
        return NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
    }
    private func imagePoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil), r = imageRect, s = scale
        return NSPoint(x: max(0, min(CGFloat(base.width), (p.x - r.minX) / s - contentOffset.x)), y: max(0, min(CGFloat(base.height), (p.y - r.minY) / s - contentOffset.y)))
    }

    // MARK: desenho

    private static let checker: NSColor = {
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { r in
            NSColor(white: 0.17, alpha: 1).setFill(); r.fill()
            NSColor(white: 0.205, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 10, height: 10).fill(); NSRect(x: 10, y: 10, width: 10, height: 10).fill()
            return true
        }
        return NSColor(patternImage: img)
    }()

    override func draw(_ dirtyRect: NSRect) {
        Self.checker.setFill(); bounds.fill()
        let r = imageRect
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 14; shadow.shadowColor = NSColor.black.withAlphaComponent(0.5); shadow.set()
        NSColor.black.setFill(); r.fill()
        NSGraphicsContext.restoreGraphicsState()
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.translateBy(x: r.minX, y: r.minY); ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: contentOffset.x, y: contentOffset.y)
        if let draft { drawDraft(draft, in: ctx) }
        if let i = selected, annotations.indices.contains(i) {
            let box = annotations[i].bounds.insetBy(dx: -4 / scale, dy: -4 / scale)
            let path = NSBezierPath(rect: box); path.lineWidth = 1.5 / scale
            path.setLineDash([5 / scale, 3 / scale], count: 2, phase: 0)
            NSColor.white.setStroke(); path.stroke()
        }
        ctx.restoreGState()
    }

    private func drawDraft(_ note: Annotation, in ctx: CGContext) {
        switch note.tool {
        case .blur, .crop:
            let full = NSRect(x: 0, y: 0, width: base.width, height: base.height)
            if note.tool == .crop {
                let dim = NSBezierPath(rect: full); dim.appendRect(note.rect); dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.55).setFill(); dim.fill()
            }
            let frame = NSBezierPath(rect: note.rect); frame.lineWidth = 1.5 / scale
            frame.setLineDash([6 / scale, 4 / scale], count: 2, phase: 0)
            NSColor.white.setStroke(); frame.stroke()
        case .magnifier:
            let frame = NSBezierPath(ovalIn: note.rect); frame.lineWidth = note.width; note.color.setStroke(); frame.stroke()
        default: note.draw(in: ctx, canvas: CGSize(width: base.width, height: base.height))
        }
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        guard imageRect.insetBy(dx: -8, dy: -8).contains(convert(event.locationInWindow, from: nil)) else { selected = nil; needsDisplay = true; return }
        switch tool {
        case .select:
            if let i = selected, annotations.indices.contains(i), annotations[i].tool == .picture, hypot(p.x - annotations[i].b.x, p.y - annotations[i].a.y) < 14 / scale {
                resizing = true; dragLast = p; dragSnapshotTaken = false; return   // canto inferior direito: redimensiona
            }
            selected = annotations.lastIndex { $0.bounds.contains(p) }
            dragLast = p; dragSnapshotTaken = false
            if let i = selected { colors[annotations[i].tool] = annotations[i].color }
            needsDisplay = true
        case .text: beginText(at: p)
        case .counter: add(makeAnnotation(.counter, from: p, to: p))
        default: draft = makeAnnotation(tool, from: p, to: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if resizing, let i = selected, annotations.indices.contains(i), let pic = annotations[i].picture {
            if !dragSnapshotTaken { pushUndo(); dragSnapshotTaken = true }
            let ratio = CGFloat(pic.height) / CGFloat(pic.width), a = annotations[i].a
            let w = max(16, p.x - a.x)
            annotations[i].b = NSPoint(x: a.x + w, y: a.y + w * ratio)   // mantém a proporção; o canto de cima sobe
            rerender(); return
        }
        if tool == .select, let i = selected, let last = dragLast {
            if !dragSnapshotTaken { pushUndo(); dragSnapshotTaken = true }
            annotations[i].move(by: NSSize(width: p.x - last.x, height: p.y - last.y)); dragLast = p
            rerender(); return
        }
        guard draft != nil else { return }
        draft?.b = p
        if draft?.tool == .freehand { draft?.path.append(p) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragLast = nil; resizing = false
        guard let note = draft else { return }
        draft = nil
        let big = hypot(note.b.x - note.a.x, note.b.y - note.a.y) >= 3
        switch note.tool {
        case .crop: if big { crop(to: note.rect) }
        case .freehand: if note.path.count > 2 { add(note) }
        default: if big { add(note) }
        }
        needsDisplay = true
    }

    // MARK: texto no próprio canvas

    private func beginText(at p: NSPoint) {
        let r = imageRect, s = scale
        var probe = makeAnnotation(.text, from: p, to: p); probe.text = "M"
        let field = NSTextField(frame: NSRect(x: r.minX + p.x * s, y: r.minY + p.y * s - probe.textSize.height * s - 4, width: 260, height: probe.textSize.height * s + 8))
        field.font = NSFont.boldSystemFont(ofSize: probe.fontSize * s)
        field.textColor = color; field.drawsBackground = false; field.isBordered = false; field.focusRingType = .none
        field.placeholderString = "Texto"; field.delegate = self
        addSubview(field); editingField = field; editingOrigin = p
        window?.makeFirstResponder(field)
    }

    func commitText() {
        guard let field = editingField else { return }
        editingField = nil
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !value.isEmpty else { return }
        var note = makeAnnotation(.text, from: editingOrigin, to: editingOrigin); note.text = value
        add(note)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) { commitText(); return true }
        if selector == #selector(cancelOperation(_:)) { editingField?.stringValue = ""; commitText(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    // MARK: teclado e zoom

    private static let keys: [String: Tool] = ["v": .select, "a": .arrow, "l": .line, "r": .rectangle, "o": .oval, "p": .freehand, "t": .text, "h": .highlight, "b": .blur, "n": .counter, "c": .crop, "s": .spotlight, "m": .magnifier, "e": .ruler]
    var onToolKey: ((Tool) -> Void)?
    var onEscape: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onHover: ((NSColor?) -> Void)?
    var onCopyColor: ((String) -> Void)?
    private(set) var hoverColor: NSColor?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelected(); return }
        if event.keyCode == 48, let c = hoverColor { onCopyColor?(Self.hex(c)); return }
        if event.keyCode == 53 { if selected != nil { selected = nil; needsDisplay = true } else { onEscape?() }; return }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(), let t = Self.keys[key] { onToolKey?(t); return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard editingField == nil, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { redoEdit() } else { undoEdit() }
            return true
        }
        return onKeyEquivalent?(event) ?? super.performKeyEquivalent(with: event)
    }

    // MARK: cor sob o mouse (Tab copia) e redimensionar

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let view = convert(event.locationInWindow, from: nil)
        hoverColor = imageRect.contains(view) ? color(at: imagePoint(event)) : nil
        onHover?(hoverColor)
    }
    override func mouseExited(with event: NSEvent) { hoverColor = nil; onHover?(nil) }

    /// Cor do pixel da imagem final em `p` (pixels, origem embaixo à esquerda).
    func color(at p: NSPoint) -> NSColor? {
        guard let flat = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(flat, in: CGRect(x: -floor(p.x + contentOffset.x), y: -floor(p.y + contentOffset.y), width: CGFloat(flat.width), height: CGFloat(flat.height)))
        let b = data.assumingMemoryBound(to: UInt8.self)
        return NSColor(srgbRed: CGFloat(b[0]) / 255, green: CGFloat(b[1]) / 255, blue: CGFloat(b[2]) / 255, alpha: 1)
    }

    static func hex(_ c: NSColor) -> String {
        let c = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    /// Escala a imagem e os objetos para `size` (pixels).
    func resize(to size: CGSize) {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        guard w != base.width || h != base.height,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return }
        let fx = CGFloat(w) / CGFloat(base.width), fy = CGFloat(h) / CGFloat(base.height), k = (fx + fy) / 2
        pushUndo(); base = scaled
        annotations = annotations.map { var n = $0; n.a.x *= fx; n.a.y *= fy; n.b.x *= fx; n.b.y *= fy; n.path = n.path.map { NSPoint(x: $0.x * fx, y: $0.y * fy) }; n.width *= k; return n }
        selected = nil; rerender(); updateFrame()
    }

    /// ⌘ + roda do mouse dá zoom; sem ⌘ a roda rola a imagem.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        let sign: CGFloat = CapturePrefs.bool(CapturePrefs.Key.reverseZoom) ? -1 : 1
        zoom = max(0.05, min(8, scale * (1 + sign * event.scrollingDeltaY * 0.01)))
    }

    override func magnify(with event: NSEvent) { zoom = max(0.05, min(8, scale * (1 + event.magnification))) }
    override func viewDidEndLiveResize() { updateFrame() }
}
