import Foundation
import AppKit
import Vision

/// Configuração do S3 (bucket, região, pasta, validade) em JSON; as chaves ficam no Keychain.
final class S3Settings: ObservableObject {
    static let shared = S3Settings()
    @Published var config = S3Config()
    @Published var accessKey = ""
    @Published var secret = ""
    @Published private(set) var hasCredentials = false
    private let file: URL

    init(directory: URL? = nil, loadKeychain: Bool = true) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iLand")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        file = dir.appendingPathComponent("s3.json")
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(S3Config.self, from: d) { config = c }
        if loadKeychain, !UsageFetcher.keychainDisabled { hasCredentials = S3Keychain.load() != nil }
    }

    var ready: Bool { config.isComplete && hasCredentials }

    /// Salva a configuração e, se as chaves foram digitadas, guarda no Keychain e apaga da memória do formulário.
    func save(persistCredentials: Bool = true) {
        if let d = try? JSONEncoder().encode(config) { try? d.write(to: file, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        guard persistCredentials else { return }
        let k = accessKey.trimmingCharacters(in: .whitespacesAndNewlines), s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty, !s.isEmpty, S3Keychain.save(S3Credentials(accessKey: k, secret: s)) { hasCredentials = true }
        accessKey = ""; secret = ""
    }

    func removeCredentials() { S3Keychain.delete(); hasCredentials = false }
    func credentials() -> S3Credentials? { UsageFetcher.keychainDisabled ? nil : S3Keychain.load() }
}

/// A captura atual é mantida como PNG, compartilhado por todas as ações.
final class CaptureModel: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var message = ""
    @Published private(set) var uploading = false
    @Published private(set) var lastLink: URL?
    @Published private(set) var capturing = false
    @Published private(set) var uploadProgress = 0.0
    private var currentUpload: S3Upload?
    @Published var editingConfig = false
    struct Dependencies {
        var capture: (CaptureMode, Int, URL, @escaping (Bool) -> Void) -> Void = { ScreenCapture.run($0, delay: $1, to: $2, $3) }
        var edit: (NSImage, CaptureEditorActions, @escaping (NSImage) -> Bool) -> Void = { CaptureEditorController.show(image: $0, actions: $1, onApply: $2) }
        var recognize: (Data) -> String = { CaptureText.recognize($0) }
        var upload: (URL, S3Config, S3Credentials, @escaping (Double) -> Void, @escaping (Result<URL, Error>) -> Void) -> S3Upload? = { S3Client.upload(file: $0, config: $1, creds: $2, progress: $3, completion: $4) }
        var ready: (S3Settings) -> Bool = { $0.ready }
        var credentials: (S3Settings) -> S3Credentials? = { $0.ready ? $0.credentials() : nil }
        var clipboard: (String) -> Void = { text in let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string) }
        var showPreview: (CaptureModel) -> Void = { CapturePreviewController.shared.show(model: $0) }
        var hidePreview: () -> Void = { CapturePreviewController.shared.hide() }
        var notify: (String) -> Void = { Toast.show($0) }
        var overlayVisible: () -> Bool = { CapturePreviewController.shared.isVisible || CaptureEditorController.isOpen }
        var saveFile: (Data) throws -> URL = { png in
            let factor = CapturePrefs.bool(CapturePrefs.Key.downscale) ? (NSScreen.main?.backingScaleFactor ?? 1) : 1
            return try CaptureOutput.save(png, to: CapturePrefs.saveFolder, formatPref: CapturePrefs.string(CapturePrefs.Key.format), downscaleBy: factor)
        }
        var scheduleCapture: (@escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: $0) }
        var background: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
        var main: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    }
    let settings: S3Settings
    private let dependencies: Dependencies
    init(settings: S3Settings = .shared, dependencies: Dependencies = Dependencies()) {
        self.settings = settings; self.dependencies = dependencies
    }
    private var png: Data?
    private var captureID = UUID()
    private var clearWork: DispatchWorkItem?

    private func say(_ s: String, sticky: Bool = false) {
        message = s
        clearWork?.cancel()
        guard !sticky else { return }
        if !s.isEmpty, !dependencies.overlayVisible() { dependencies.notify(s) }
        let w = DispatchWorkItem { [weak self] in self?.message = "" }
        clearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    private func replaceImage(_ data: Data) -> Bool {
        guard let img = NSImage(data: data) else { return false }
        png = data; image = img; captureID = UUID(); lastLink = nil
        return true
    }

    private func temporaryPNG() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iland-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("capture.png")
    }

    private static func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func capture() { capture(.area) }

    /// Reconhece o texto (ou QR) de uma área da tela e copia, sem abrir miniatura nem trocar a captura atual.
    func captureText() { capture(.area, textOnly: true) }

    func capture(_ mode: CaptureMode, delay: Int = 0, textOnly: Bool = false, then: String? = nil) {
        guard !capturing else { return }
        guard !uploading else { say("Aguarde o envio terminar."); return }
        capturing = true
        dependencies.hidePreview()
        NotificationCenter.default.post(name: .ilandCollapse, object: nil)
        let url: URL
        do { url = try temporaryPNG() } catch { capturing = false; if image != nil { dependencies.showPreview(self) }; say("Não consegui preparar a captura: \(error.localizedDescription)"); return }
        dependencies.scheduleCapture { [weak self] in
            guard let self else { Self.cleanup(url); return }
            self.dependencies.capture(mode, delay, url) { [weak self] ok in
                defer { Self.cleanup(url) }
                guard let self else { return }
                self.capturing = false
                if ok { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
                guard ok, let data = try? Data(contentsOf: url) else {
                    if self.image != nil { dependencies.showPreview(self) }
                    self.say("Captura cancelada (ou falta permissão de gravação de tela)"); return
                }
                if textOnly { self.copyText(of: data); return }
                guard self.replaceImage(data) else { self.say("Captura cancelada (ou falta permissão de gravação de tela)"); return }
                self.afterCapture(then: then)
            }
        }
    }

    /// O que acontece depois da captura vem dos ajustes: copiar, salvar e mostrar (miniatura ou editor).
    private func afterCapture(then: String? = nil) {
        var notes: [String] = []
        if CapturePrefs.bool(CapturePrefs.Key.copy) { copyImage(announce: false); notes.append("copiada") }
        if CapturePrefs.bool(CapturePrefs.Key.save), let png {
            do { _ = try dependencies.saveFile(png); notes.append("salva") }
            catch { say("Não consegui salvar a captura: \(error.localizedDescription)"); return }
        }
        say(notes.isEmpty ? "Capturado. Copie ou envie." : "Captura " + notes.joined(separator: " e "))
        switch then ?? (CapturePrefs.string(CapturePrefs.Key.afterArea) == "editor" ? "editor" : (CapturePrefs.bool(CapturePrefs.Key.show) ? "thumbnail" : "")) {
        case "editor": editImage()
        case "thumbnail": dependencies.showPreview(self)
        case "copy": copyImage()
        case "save": saveImage()
        case "upload": upload()
        default: break
        }
    }

    private func copyText(of data: Data) {
        say("Reconhecendo texto…", sticky: true)
        dependencies.background { [weak self] in
            guard let self else { return }
            let text = self.dependencies.recognize(data)
            self.dependencies.main { [weak self] in
                guard let self else { return }
                guard !text.isEmpty else { self.say("Nenhum texto reconhecido."); return }
                self.dependencies.clipboard(text)
                self.say("Texto copiado (\(text.count) caracteres)")
            }
        }
    }

    func showLibrary() { CaptureLibrary.shared.show { [weak self] in self?.openImage(at: $0) } }

    func openImage(at url: URL) { load(NSImage(contentsOf: url)) }

    /// Reabre a miniatura da última captura.
    func showLast() {
        guard image != nil else { say("Ainda não há captura."); return }
        dependencies.showPreview(self)
    }

    func copyImage() { copyImage(announce: true) }

    private func copyImage(announce: Bool) {
        guard let png else { return }
        let pb = NSPasteboard.general; pb.clearContents()
        if pb.setData(png, forType: .png) { if announce { say("Imagem copiada") } }
        else { say("Não consegui copiar a imagem.") }
    }

    /// Salva direto na pasta dos ajustes (formato e 1× também vêm de lá).
    func saveImage() {
        guard let png else { return }
        do { let url = try dependencies.saveFile(png); say("Salvo em \(url.deletingLastPathComponent().lastPathComponent)") }
        catch { say("Não consegui salvar: \(error.localizedDescription)") }
    }

    func saveImageAs() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "captura.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url, options: .atomic); self?.say("Imagem salva") }
            catch { self?.say("Não consegui salvar: \(error.localizedDescription)") }
        }
    }

    func editImage() {
        guard let image else { return }
        var id = captureID
        let actions = CaptureEditorActions(copy: { [weak self] in self?.copyImage() }, save: { [weak self] in self?.saveImage() },
                                           pin: { [weak self] in self?.pinImage() }, upload: { [weak self] in self?.upload() },
                                           ocr: { [weak self] in self?.recognizeText() }, saveAs: { [weak self] in self?.saveImageAs() },
                                           open: { [weak self] in self?.openImageFile() }, openClipboard: { [weak self] in self?.openClipboardImage() },
                                           print: { [weak self] in self?.printImage() }, addCapture: { [weak self] in self?.grabPicture($0) }, message: { [weak self] in self?.message ?? "" })
        dependencies.edit(image, actions) { [weak self] edited in
            guard let self else { return false }
            guard !self.uploading else { self.say("Aguarde o envio terminar para aplicar a edição."); return false }
            guard !self.capturing else { self.say("Aguarde a captura terminar para aplicar a edição."); return false }
            guard self.captureID == id else { self.say("A captura mudou; a edição não foi aplicada."); return false }
            guard let tiff = edited.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]), self.replaceImage(data) else {
                self.say("Não consegui aplicar a edição."); return false
            }
            id = self.captureID
            self.say("Edição aplicada")
            return true
        }
    }

    /// Abre uma imagem de arquivo no editor.
    func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(NSImage(contentsOf: url))
    }

    /// Abre no editor a imagem que está na área de transferência.
    func openClipboardImage() {
        guard let img = NSImage(pasteboard: .general) else { say("Não há imagem na área de transferência."); return }
        load(img)
    }

    private func load(_ img: NSImage?) {
        guard let img, let tiff = img.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]), replaceImage(data) else {
            say("Não consegui abrir a imagem."); return
        }
        editImage()
    }

    func printImage() {
        guard let image else { return }
        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size)); view.image = image
        let info = NSPrintInfo.shared; info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        info.horizontalPagination = .fit; info.verticalPagination = .fit
        NSPrintOperation(view: view, printInfo: info).run()
    }

    func recognizeText() {
        guard let png else { return }
        let id = captureID
        say("Reconhecendo texto…", sticky: true)
        dependencies.background { [weak self] in
            guard let self else { return }
            let text = self.dependencies.recognize(png)
            self.dependencies.main { [weak self] in
                guard let self, self.captureID == id else { return }
                guard !text.isEmpty else { self.say("Nenhum texto reconhecido."); return }
                self.dependencies.clipboard(text)
                self.say("Texto copiado")
            }
        }
    }

    func pinImage() {
        guard let image else { return }
        CapturePinController.shared.show(image: image)
    }

    /// Captura uma área só para entregar ao editor (não troca a captura atual).
    func grabPicture(_ done: @escaping (NSImage?) -> Void) {
        guard !capturing, let url = try? temporaryPNG() else { return done(nil) }
        capturing = true
        dependencies.scheduleCapture { [weak self] in
            guard let self else { Self.cleanup(url); return done(nil) }
            self.dependencies.capture(.area, 0, url) { [weak self] ok in
                defer { Self.cleanup(url) }
                self?.capturing = false
                done(ok ? (try? Data(contentsOf: url)).flatMap { NSImage(data: $0) } : nil)
            }
        }
    }

    func cancelUpload() { currentUpload?.cancel() }

    func upload() {
        guard let png, !uploading else { return }
        guard !capturing else { say("Aguarde a captura terminar."); return }
        guard settings.config.enabled else { say("O envio está desligado nos Ajustes (aba Captura)."); return }
        guard dependencies.ready(settings) else { editingConfig = true; say("Abra a aba Captura nos Ajustes e configure o envio."); return }
        guard let creds = dependencies.credentials(settings) else { say("Não consegui ler as chaves do Keychain."); return }
        let id = captureID, config = settings.config
        let url: URL
        do {
            url = try temporaryPNG()
            do {
                try png.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { Self.cleanup(url); throw error }
        }
        catch { say("Não consegui preparar o envio: \(error.localizedDescription)"); return }
        uploading = true; uploadProgress = 0; say("Enviando…", sticky: true)
        dependencies.background { [weak self] in
            guard let self else { Self.cleanup(url); return }
            let handle = self.dependencies.upload(url, config, creds, { progress in
                self.dependencies.main { [weak self] in
                    guard let self, self.uploading else { return }
                    self.uploadProgress = progress
                    self.say("Enviando… \(Int(progress * 100))%", sticky: true)
                }
            }) { result in
                Self.cleanup(url)
                self.dependencies.main { [weak self] in
                    guard let self else { return }
                    self.uploading = false; self.currentUpload = nil
                    guard self.captureID == id else { return }
                    switch result {
                    case .success(let link):
                        self.lastLink = link
                        if config.sharing == "none" { self.say("Enviado (sem link, como pedido nos Ajustes)."); return }
                        self.dependencies.clipboard(link.absoluteString)
                        self.say(config.sharing == "public" ? "Enviado. Link público copiado." : "Enviado. Link copiado (vale \(config.expiresHours) h).")
                    case .failure(let error):
                        if (error as? URLError)?.code == .cancelled { self.say("Envio cancelado.") } else { self.say("Falhou: \(error.localizedDescription)") }
                    }
                }
            }
            self.dependencies.main { [weak self] in if self?.uploading == true { self?.currentUpload = handle } else { handle?.cancel() } }
        }
    }
}

/// Reconhecimento de texto da imagem (idiomas e quebras vêm dos ajustes). Se houver QR code, devolve o conteúdo dele.
enum CaptureText {
    static func recognize(_ data: Data) -> String {
        let qr = VNDetectBarcodesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLanguages = CapturePrefs.ocrLanguages
        // Tela inteira em Retina (7 MP) leva ~30 s no modo preciso; acima de 3 MP usa o modo rápido.
        let pixels = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            .map { (($0[kCGImagePropertyPixelWidth] as? Int) ?? 0) * (($0[kCGImagePropertyPixelHeight] as? Int) ?? 0) } ?? 0
        text.recognitionLevel = pixels > 3_000_000 ? .fast : .accurate
        text.usesLanguageCorrection = text.recognitionLevel == .accurate
        guard (try? VNImageRequestHandler(data: data).perform([qr, text])) != nil else { return "" }
        let codes = (qr.results ?? []).compactMap { $0.payloadStringValue }
        if !codes.isEmpty { return codes.joined(separator: "\n") }
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return CapturePrefs.bool(CapturePrefs.Key.ocrBreaks) ? lines.joined(separator: " ") : lines.joined(separator: "\n")
    }
}
