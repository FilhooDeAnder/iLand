import AppKit

/// Ações da miniatura que o editor também oferece. Todas usam a imagem já editada.
struct CaptureEditorActions {
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var pin: () -> Void = {}
    var upload: () -> Void = {}
    var ocr: () -> Void = {}
    var saveAs: () -> Void = {}
    var open: () -> Void = {}
    var openClipboard: () -> Void = {}
    var print: () -> Void = {}
    var addCapture: (@escaping (NSImage?) -> Void) -> Void = { $0(nil) }
    var message: () -> String = { "" }
}

private func symbol(_ names: String...) -> NSImage? {
    for name in names { if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return image } }
    return nil
}

private final class IconButton: NSButton {
    var active = false { didSet { layer?.backgroundColor = active ? NSColor.white.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor } }

    init(_ symbols: [String], tip: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        image = symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: tip) }.first
        imagePosition = .imageOnly; isBordered = false; contentTintColor = NSColor(white: 0.92, alpha: 1)
        toolTip = tip; setAccessibilityLabel(tip)
        self.target = target; self.action = action
        wantsLayer = true; layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { nil }
}

final class CaptureEditorController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [CaptureEditorController] = []
    static var isOpen: Bool { !openEditors.isEmpty }
    private let canvas: CaptureEditorCanvas
    private let onApply: (NSImage) -> Bool
    private let actions: CaptureEditorActions
    private var toolButtons: [CaptureEditorCanvas.Tool: IconButton] = [:]
    private let undoButton: IconButton, redoButton: IconButton
    private let colorWell = NSColorWell(style: .minimal)
    private let sizeSlider = NSSlider(value: 4, minValue: 1, maxValue: 12, target: nil, action: nil)
    private let info = NSTextField(labelWithString: "")
    private let zoomButton = NSButton(title: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var statusTimer: Timer?

    static func show(image: NSImage, actions: CaptureEditorActions = .init(), onApply: @escaping (NSImage) -> Bool) {
        guard let editor = CaptureEditorController(image: image, actions: actions, onApply: onApply) else { return }
        openEditors.append(editor)
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        editor.window?.makeFirstResponder(editor.canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init?(image: NSImage, actions: CaptureEditorActions, onApply: @escaping (NSImage) -> Bool) {
        guard let canvas = CaptureEditorCanvas(image: image) else { return nil }
        self.canvas = canvas; self.onApply = onApply; self.actions = actions
        undoButton = IconButton(["arrow.uturn.backward"], tip: "Desfazer (⌘Z)", target: nil, action: #selector(undoEdit))
        redoButton = IconButton(["arrow.uturn.forward"], tip: "Refazer (⇧⌘Z)", target: nil, action: #selector(redoEdit))
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let (pw, ph) = canvas.pixelSize, backing = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: min(visible.width * 0.9, max(1220, CGFloat(pw) / backing + 120)), height: min(visible.height * 0.9, max(560, CGFloat(ph) / backing + 52 + 120)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.115, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1220, height: 420)
        window.center(); window.delegate = self
        undoButton.target = self; redoButton.target = self
        build(in: window)
        canvas.onChange = { [weak self] in self?.refresh() }
        canvas.onToolKey = { [weak self] in self?.select($0) }
        canvas.onEscape = { [weak self] in self?.escape() }
        canvas.onKeyEquivalent = { [weak self] in self?.shortcut($0) ?? false }
        canvas.onHover = { [weak self] _ in self?.refresh() }
        canvas.onCopyColor = { hex in
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(hex, forType: .string)
            Toast.show("Cor copiada: \(hex)")
        }
        if CapturePrefs.bool(CapturePrefs.Key.zoom100) { canvas.zoom = canvas.actualScale }
        select(.arrow); refresh()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.pollStatus() }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: montagem

    private func build(in window: NSWindow) {
        let container = NSView(); window.contentView = container
        func button(_ symbols: [String], _ tip: String, _ action: Selector) -> IconButton { IconButton(symbols, tip: tip, target: self, action: action) }
        func separator() -> NSView {
            let box = NSBox(); box.boxType = .separator; box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: 1).isActive = true; box.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return box
        }
        let output: [NSView] = [button(["doc.on.doc"], "Copiar imagem", #selector(doCopy)), button(["square.and.arrow.down"], "Salvar imagem", #selector(doSave)),
                                button(["pin"], "Fixar na tela", #selector(doPin)), button(["icloud.and.arrow.up"], "Enviar ao S3", #selector(doUpload)),
                                button(["text.viewfinder"], "Copiar texto da imagem", #selector(doOCR))]
        let defs: [(CaptureEditorCanvas.Tool, [String], String)] = [
            (.select, ["cursorarrow"], "Selecionar e mover (V)"), (.arrow, ["arrow.up.right"], "Seta (A)"), (.line, ["line.diagonal"], "Linha (L)"),
            (.rectangle, ["rectangle"], "Retângulo (R)"), (.oval, ["circle"], "Oval (O)"), (.freehand, ["pencil.tip", "pencil"], "Desenho livre (P)"),
            (.text, ["textformat"], "Texto (T)"), (.highlight, ["highlighter", "paintbrush.pointed"], "Marca-texto (H)"),
            (.blur, ["drop", "drop.fill"], "Ocultar com pixels (B)"), (.spotlight, ["flashlight.on.fill", "sun.max"], "Holofote (S)"),
            (.magnifier, ["magnifyingglass"], "Lupa (M)"), (.ruler, ["ruler"], "Régua (E)"), (.counter, ["1.circle"], "Contador (N)"), (.crop, ["crop"], "Recortar (C)")]
        for (tool, names, tip) in defs { let b = button(names, tip, #selector(pickTool(_:))); toolButtons[tool] = b }
        colorWell.target = self; colorWell.action = #selector(pickColor(_:)); colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 30).isActive = true; colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorWell.toolTip = "Cor"
        sizeSlider.target = self; sizeSlider.action = #selector(pickSize(_:)); sizeSlider.toolTip = "Espessura / tamanho"
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false; sizeSlider.widthAnchor.constraint(equalToConstant: 64).isActive = true
        info.font = .systemFont(ofSize: 11); info.textColor = NSColor(white: 0.7, alpha: 1)
        info.alignment = .right; info.lineBreakMode = .byTruncatingTail
        info.translatesAutoresizingMaskIntoConstraints = false
        info.widthAnchor.constraint(equalToConstant: 230).isActive = true   // largura fixa: o texto da cor sob o mouse não pode mexer na janela
        zoomButton.isBordered = false; zoomButton.font = .systemFont(ofSize: 11); zoomButton.contentTintColor = NSColor(white: 0.7, alpha: 1)
        zoomButton.target = self; zoomButton.action = #selector(toggleZoom); zoomButton.toolTip = "Alternar entre ajustar e 100%"
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let props = button(["slider.horizontal.3"], "Propriedades do objeto", #selector(showProperties(_:)))
        let backdrop = button(["photo.on.rectangle", "rectangle.on.rectangle"], "Fundo (gradiente, margem, sombra)", #selector(showBackdrop(_:)))
        let more = button(["ellipsis.circle"], "Mais ações", #selector(showMore(_:)))
        let bar = NSStackView(views: output + [separator()] + defs.map { toolButtons[$0.0]! } + [separator(), colorWell, sizeSlider, props, backdrop, spacer, undoButton, redoButton, more, separator(), info, zoomButton])
        bar.orientation = .horizontal; bar.spacing = 3; bar.alignment = .centerY; bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setCustomSpacing(10, after: output.last!)
        container.addSubview(bar)

        let scroll = NSScrollView(); scroll.documentView = canvas
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in self?.canvas.updateFrame(); self?.canvas.needsDisplay = true; self?.refresh() }
        scroll.postsFrameChangedNotifications = true

        status.font = .systemFont(ofSize: 12, weight: .medium); status.textColor = .white; status.alignment = .center
        status.wantsLayer = true; status.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor; status.layer?.cornerRadius = 8
        status.isHidden = true; status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 11), bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 82),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14), bar.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 52), scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            status.centerXAnchor.constraint(equalTo: container.centerXAnchor), status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            status.heightAnchor.constraint(equalToConstant: 28), status.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        ])
    }

    // MARK: estado da barra

    private func select(_ tool: CaptureEditorCanvas.Tool) {
        canvas.tool = tool
        toolButtons.forEach { $0.value.active = $0.key == tool }
        colorWell.color = canvas.color
        window?.makeFirstResponder(canvas)
    }

    private func refresh() {
        undoButton.isEnabled = canvas.canUndo; redoButton.isEnabled = canvas.canRedo
        undoButton.alphaValue = canvas.canUndo ? 1 : 0.35; redoButton.alphaValue = canvas.canRedo ? 1 : 0.35
        let (w, h) = canvas.pixelSize
        info.stringValue = canvas.hoverColor.map { "\(CaptureEditorCanvas.hex($0))  ·  ⇥ copia  ·  \(w)×\(h) px" } ?? "\(w)×\(h) px"
        let backing = window?.backingScaleFactor ?? 2
        zoomButton.title = "\(Int((canvas.scale * backing * 100).rounded()))%"
    }

    private func pollStatus() {
        let text = actions.message()
        status.isHidden = text.isEmpty
        status.stringValue = "  \(text)  "
    }

    // MARK: ações

    @objc private func pickTool(_ sender: IconButton) { if let tool = toolButtons.first(where: { $0.value === sender })?.key { select(tool) } }
    @objc private func pickColor(_ sender: NSColorWell) { canvas.color = sender.color; window?.makeFirstResponder(canvas) }
    @objc private func pickSize(_ sender: NSSlider) { canvas.sizeSetting = CGFloat(sender.doubleValue) }
    @objc private func undoEdit() { canvas.undoEdit() }
    @objc private func redoEdit() { canvas.redoEdit() }
    @objc private func toggleZoom() { canvas.zoom = canvas.zoom == nil ? canvas.actualScale : nil }
    /// Esc fecha o editor; conforme os ajustes, antes copia ou salva a imagem.
    private func escape() {
        switch CapturePrefs.string(CapturePrefs.Key.esc) {
        case "copy": run(actions.copy)
        case "save": run(actions.save)
        default: break
        }
        window?.close()
    }

    @objc private func showBackdrop(_ sender: NSButton) {
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = BackdropPanel(canvas: canvas)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func showProperties(_ sender: NSButton) {
        let popover = NSPopover(); popover.behavior = .transient
        let opacity = NSSlider(value: Double(canvas.opacity), minValue: 0.1, maxValue: 1, target: self, action: #selector(setOpacity(_:)))
        let fill = NSButton(checkboxWithTitle: "Preencher (retângulo, oval)", target: self, action: #selector(setFill(_:))); fill.state = canvas.fill ? .on : .off
        let dash = NSButton(checkboxWithTitle: "Linha tracejada", target: self, action: #selector(setDash(_:))); dash.state = canvas.dashed ? .on : .off
        let arrow = NSSegmentedControl(labels: ["Aberta", "Cheia", "Dupla"], trackingMode: .selectOne, target: self, action: #selector(setArrow(_:)))
        arrow.selectedSegment = canvas.arrowStyle.rawValue
        func row(_ title: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [label, control]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3; return stack
        }
        let content = NSStackView(views: [row("Opacidade", opacity), row("Ponta da seta", arrow), fill, dash])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.frame.size = content.fittingSize; opacity.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let controller = NSViewController(); controller.view = content; popover.contentViewController = controller
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    @objc private func setOpacity(_ s: NSSlider) { canvas.opacity = CGFloat(s.doubleValue) }
    @objc private func setFill(_ s: NSButton) { canvas.fill = s.state == .on }
    @objc private func setDash(_ s: NSButton) { canvas.dashed = s.state == .on }
    @objc private func setArrow(_ s: NSSegmentedControl) { canvas.arrowStyle = Annotation.ArrowStyle(rawValue: s.selectedSegment) ?? .open }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = self; menu.addItem(i)
        }
        item("Abrir arquivo…", "o", [.command], #selector(doOpen)); item("Abrir da área de transferência", "v", [.command, .shift], #selector(doOpenClipboard))
        menu.addItem(.separator())
        item("Salvar na pasta", "s", [.command], #selector(doSave)); item("Salvar como…", "s", [.command, .shift], #selector(doSaveAs))
        item("Enviar ao S3", "e", [.command], #selector(doUpload)); item("Fixar na tela", "p", [.command], #selector(doPin)); item("Imprimir…", "p", [.command, .shift], #selector(doPrint))
        menu.addItem(.separator())
        item("Adicionar captura…", "", [], #selector(addCapture)); item("Redimensionar imagem…", "", [], #selector(resizeImage))
        menu.addItem(.separator())
        item("Aumentar zoom", "+", [.command], #selector(zoomIn)); item("Diminuir zoom", "-", [.command], #selector(zoomOut)); item("Ajustar à janela", "0", [.command], #selector(zoomFit)); item("Tamanho real (100%)", "1", [.command], #selector(zoomActual))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Atalhos ⌘ do editor (os mesmos do menu "Mais ações").
    private func shortcut(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "c": doCopy()
        case "s": if shift { doSaveAs() } else { doSave() }
        case "e": doUpload()
        case "p": if shift { doPrint() } else { doPin() }
        case "o": doOpen()
        case "v" where shift: doOpenClipboard()
        case "=", "+": zoomIn()
        case "-": zoomOut()
        case "0": zoomFit()
        case "1": zoomActual()
        default: return false
        }
        return true
    }

    @objc private func zoomIn() { canvas.zoom = min(8, canvas.scale * 1.25) }
    @objc private func zoomOut() { canvas.zoom = max(0.05, canvas.scale / 1.25) }
    @objc private func zoomFit() { canvas.zoom = nil }
    @objc private func zoomActual() { canvas.zoom = canvas.actualScale }
    @objc private func doSaveAs() { run(actions.saveAs) }
    @objc private func doPrint() { run(actions.print) }
    @objc private func doOpen() { actions.open() }
    @objc private func doOpenClipboard() { actions.openClipboard() }

    /// Esconde o editor, captura outra área e põe o resultado em cima da imagem.
    @objc private func addCapture() {
        canvas.commitText()
        window?.orderOut(nil)
        actions.addCapture { [weak self] image in
            guard let self else { return }
            self.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { self.canvas.addPicture(cg) }
            else { Toast.show("Captura cancelada.") }
        }
    }

    @objc private func resizeImage() {
        let (w, h) = canvas.pixelSize
        let alert = NSAlert(); alert.messageText = "Redimensionar imagem"; alert.informativeText = "Tamanho em pixels."
        let width = NSTextField(string: "\(w)"), height = NSTextField(string: "\(h)")
        let keep = NSButton(checkboxWithTitle: "Manter a proporção (vale a largura)", target: nil, action: nil); keep.state = .on
        let stack = NSStackView(views: [NSTextField(labelWithString: "Largura"), width, NSTextField(labelWithString: "Altura"), height, keep])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6; stack.frame.size = NSSize(width: 240, height: 150)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Redimensionar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn, let nw = Double(width.stringValue), nw >= 1 else { return }
        let nh = keep.state == .on ? nw * Double(h) / Double(w) : (Double(height.stringValue) ?? Double(h))
        guard nh >= 1, nw <= 20000, nh <= 20000 else { return }
        canvas.resize(to: CGSize(width: nw, height: nh))
    }

    @objc private func doCopy() { run(actions.copy) }
    @objc private func doSave() { run(actions.save) }
    @objc private func doPin() { run(actions.pin) }
    @objc private func doUpload() { run(actions.upload) }
    @objc private func doOCR() { run(actions.ocr) }

    /// Aplica a edição à captura antes da ação, para copiar, salvar e enviar a versão editada.
    private func run(_ action: () -> Void) {
        canvas.commitText()
        if canvas.dirty {
            guard onApply(canvas.image) else { NSSound.beep(); pollStatus(); return }
            canvas.markApplied()
        }
        action()
    }

    func windowWillClose(_ notification: Notification) {
        canvas.commitText()
        if canvas.dirty, onApply(canvas.image) { canvas.markApplied() }
        statusTimer?.invalidate()
        Self.openEditors.removeAll { $0 === self }
    }
}
