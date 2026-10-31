import AppKit
import SwiftUI

/// Miniatura pós-captura (estilo Shottr): painel escuro e flutuante, independente do notch.
final class CapturePreviewController {
    static let shared = CapturePreviewController()
    private var panel: NSPanel?
    private var outsideMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    func hide() {
        panel?.orderOut(nil)
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    func show(model: CaptureModel) {
        if panel == nil {
            let window = ThumbPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 370),
                                    styleMask: [.borderless],
                                    backing: .buffered, defer: false)
            window.onClose = { [weak self] in self?.hide() }
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            panel = window
        }
        guard let panel = panel as? ThumbPanel else { return }
        panel.model = model
        let wasVisible = panel.isVisible
        panel.contentView = NSHostingView(rootView: CapturePreviewView(model: model, close: { [weak self] in self?.hide() }))
        if !wasVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.minY + 20))
        }
        // Sem ativar o app o teclado não chega ao painel e os atalhos não funcionam.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // "Fechar sozinha (clique fora)": um clique em qualquer lugar fora do painel fecha a miniatura.
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if CapturePrefs.string(CapturePrefs.Key.thumbClose) == "outside" {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, let p = self.panel, !p.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
    }
}

/// Painel da miniatura: recebe o teclado sem ativar o app e atende os atalhos dos botões.
private final class ThumbPanel: NSPanel {
    weak var model: CaptureModel?
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard mods.isEmpty || mods == .command else { return super.keyDown(with: event) }
        switch (event.keyCode, key) {
        case (53, _): onClose?()
        case (36, _), (76, _), (_, "e") where mods.isEmpty: model.editImage()
        case (_, "c"): model.copyImage()
        case (_, "s"): model.saveImage()
        case (_, "e"): model.upload()
        case (_, "u"): model.upload()
        case (_, "t"): model.recognizeText()
        case (_, "p"): model.pinImage()
        default: super.keyDown(with: event)
        }
    }

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// Arrasta a janela pela faixa do topo (fora do botão de fechar).
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let p = event.locationInWindow
            dragStart = p.y > frame.height - 30 && p.x > 50 ? (NSEvent.mouseLocation, frame.origin) : nil
        case .leftMouseDragged:
            if let d = dragStart {
                let m = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(x: d.origin.x + m.x - d.mouse.x, y: d.origin.y + m.y - d.mouse.y))
                return
            }
        case .leftMouseUp: dragStart = nil
        default: break
        }
        super.sendEvent(event)
    }

    /// ⌘C etc. chegam como key equivalent antes do keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), ["c", "s", "e", "t", "p"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}

private struct CapturePreviewView: View {
    @ObservedObject var model: CaptureModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 3) { ForEach(0..<5) { _ in Circle().fill(Color.white.opacity(0.35)).frame(width: 3, height: 3) } }
                HStack { iconButton("xmark", "Fechar", close, size: 12).frame(width: 34); Spacer() }
            }
            .frame(height: 30).padding(.horizontal, 10)
            Group {
                if let image = model.image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .onTapGesture { model.editImage() }
                        .help("Abrir no editor")
                        .accessibilityLabel("Prévia da captura")
                }
            }
            .padding(.horizontal, 14).frame(maxHeight: .infinity)
            HStack(spacing: 0) {
                iconButton("pencil", "Editar  (E)", model.editImage)
                iconButton("doc.on.doc", "Copiar imagem  (⌘C)", model.copyImage)
                iconButton("square.and.arrow.down", "Salvar na pasta  (⌘S)", model.saveImage)
                iconButton(model.uploading ? "xmark.circle" : "icloud.and.arrow.up", model.uploading ? "Cancelar o envio" : "Enviar ao S3  (⌘E)", model.uploading ? model.cancelUpload : model.upload)
                iconButton("text.viewfinder", "Copiar texto da imagem  (⌘T)", model.recognizeText)
                iconButton("pin", "Fixar na tela  (⌘P)", model.pinImage)
            }
            .padding(.horizontal, 10).frame(height: 50)
            Text(model.message).font(.system(size: 11)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: model.message.isEmpty ? 6 : 22)
        }
        .padding(.bottom, 4)
        .frame(width: 300, height: 370)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private func iconButton(_ symbol: String, _ title: String, _ perform: @escaping () -> Void, size: CGFloat = 16, disabled: Bool = false) -> some View {
        PreviewIcon(symbol: symbol, title: title, size: size, perform: perform).disabled(disabled)
    }
}

private struct PreviewIcon: View {
    let symbol: String, title: String, size: CGFloat
    let perform: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: size, weight: .regular))
                .foregroundColor(.white.opacity(hover ? 1 : 0.85))
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Captura fixada na tela: sem moldura, arrasta pelo fundo. Botão direito: editar, copiar, 50/100/200%, semitransparente, fechar.
final class CapturePinController: NSObject {
    static let shared = CapturePinController()
    private var panels: [PinPanel] = []

    func show(image: NSImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let panel = PinPanel(image: image)
        panel.onClose = { [weak self, weak panel] in self?.panels.removeAll { $0 === panel } }
        panels.append(panel)
        panel.orderFrontRegardless()
    }
}

private final class PinPanel: NSPanel {
    private var image: NSImage
    private let imageView = NSImageView()
    var onClose: (() -> Void)?

    init(image: NSImage) {
        self.image = image
        let scale = min(1, 600 / image.size.width, 500 / image.size.height)
        super.init(contentRect: NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isFloatingPanel = true; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false; backgroundColor = .clear; hasShadow = true; isMovableByWindowBackground = true
        imageView.image = image; imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true; imageView.layer?.cornerRadius = 6; imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1; imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        contentView = imageView
        contentAspectRatio = image.size
        center()
    }

    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with: event) } }
    override func close() { super.close(); onClose?() }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { edit() } else { super.mouseDown(with: event) } }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, checked: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.state = checked ? .on : .off; menu.addItem(item)
        }
        add("Editar", #selector(edit)); add("Copiar", #selector(copyPin))
        menu.addItem(.separator())
        add("50%", #selector(size50)); add("100%", #selector(size100)); add("200%", #selector(size200))
        add("Semitransparente", #selector(toggleTransparency), checked: alphaValue < 1)
        menu.addItem(.separator())
        add("Fechar", #selector(closePin))
        NSMenu.popUpContextMenu(menu, with: event, for: contentView ?? imageView)
    }

    @objc private func edit() {
        CaptureEditorController.show(image: image, actions: CaptureEditorActions(copy: { [weak self] in self?.copyPin() })) { [weak self] edited in
            guard let self else { return false }
            self.image = edited; self.imageView.image = edited; self.contentAspectRatio = edited.size
            return true
        }
    }
    @objc private func copyPin() {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png)
        Toast.show("Imagem copiada")
    }
    private func resize(to factor: CGFloat) {
        var f = frame
        let new = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        f.origin.y += f.height - new.height; f.size = new
        setFrame(f, display: true, animate: true)
    }
    @objc private func size50() { resize(to: 0.5) }
    @objc private func size100() { resize(to: 1) }
    @objc private func size200() { resize(to: 2) }
    @objc private func toggleTransparency() { alphaValue = alphaValue < 1 ? 1 : 0.5 }
    @objc private func closePin() { close() }
}

