import Foundation
import AppKit

// Isolate UI, keychain and networking from these behavioral tests.
enum UsageFetcher { static var keychainDisabled = true }
extension Notification.Name { static let ilandCollapse = Notification.Name("test.collapse") }
final class CapturePreviewController { static let shared = CapturePreviewController(); var isVisible = false; func hide() {}; func show(model: CaptureModel) {} }
struct CaptureEditorActions { var copy: () -> Void = {}; var save: () -> Void = {}; var pin: () -> Void = {}; var upload: () -> Void = {}; var ocr: () -> Void = {}; var saveAs: () -> Void = {}; var open: () -> Void = {}; var openClipboard: () -> Void = {}; var print: () -> Void = {}; var addCapture: (@escaping (NSImage?) -> Void) -> Void = { $0(nil) }; var message: () -> String = { "" } }
enum CaptureEditorController { static var isOpen = false; static func show(image: NSImage, actions: CaptureEditorActions, onApply: @escaping (NSImage) -> Bool) { fatalError() } }
final class CapturePinController { static let shared = CapturePinController(); func show(image: NSImage) {} }

@main struct CaptureModelTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = S3Settings(directory: directory, loadKeychain: false)
        settings.config.bucket = "test-bucket"
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        var captures: [(URL, (Bool) -> Void)] = []
        var modes: [CaptureMode] = []
        var notices: [String] = []
        var editor: ((NSImage) -> Bool)?
        var upload: ((Result<URL, Error>) -> Void)?
        var uploadURL: URL?
        var background: [() -> Void] = []
        var clipboard: [String] = []
        var d = CaptureModel.Dependencies()
        d.capture = { mode, _, url, done in modes.append(mode); captures.append((url, done)) }
        d.notify = { notices.append($0) }; d.overlayVisible = { false }
        d.edit = { _, _, callback in editor = callback }
        d.showPreview = { _ in }; d.hidePreview = {}
        d.scheduleCapture = { $0() }; d.background = { background.append($0) }; d.main = { $0() }
        d.recognize = { _ in "texto" }
        d.ready = { _ in true }; d.credentials = { _ in S3Credentials(accessKey: "fake", secret: "fake") }
        d.clipboard = { clipboard.append($0) }
        d.upload = { url, _, _, _, callback in uploadURL = url; upload = callback; return nil }
        func link(_ s: String) -> DeepLink.Command? { DeepLink.parse(URL(string: s)!) }
        assert(link("iland://grab/area?then=editor") == DeepLink.Command(kind: .grab(.area), delay: 0, then: "editor"))
        assert(link("iland://grab/fullscreen?delay=5")?.delay == 5 && link("iland://grab/fullscreen?delay=999")?.delay == 60)
        assert(link("iland://grab/scroll")?.kind == .grab(.scroll) && link("iland://grab/ocr")?.kind == .text && link("iland://open/library")?.kind == .library)
        assert(link("iland://grab/area?then=rm")?.then == nil, "unknown then is dropped")
        assert(link("iland://grab/nada") == nil && link("https://grab/area") == nil && link("iland://apagar/tudo") == nil)
        let model = CaptureModel(settings: settings, dependencies: d)
        func finishCapture() throws {
            let (url, done) = captures.removeFirst()
            let permissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
            assert(permissions.intValue & 0o777 == 0o700)
            try png.write(to: url); done(true)
            assert(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }
        model.capture(); model.capture(); assert(captures.count == 1 && model.capturing)
        try finishCapture(); assert(model.image != nil && !model.capturing)
        model.editImage(); let staleEditor = editor!
        model.recognizeText(); assert(background.count == 1)
        model.capture(); assert(!staleEditor(image)); try finishCapture()
        assert(!staleEditor(image))
        background.removeFirst()(); assert(clipboard.isEmpty) // stale OCR must not overwrite clipboard
        model.upload(); assert(model.uploading); model.upload(); assert(background.count == 1)
        model.capture(); assert(captures.isEmpty)
        model.editImage(); assert(!editor!(image))
        background.removeFirst()()
        let url = uploadURL!
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        assert(mode.intValue & 0o777 == 0o600)
        let link = URL(string: "https://example.invalid/file")!
        upload!(.success(link))
        assert(!model.uploading && model.lastLink == link && clipboard.last == link.absoluteString)
        assert(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        model.recognizeText(); background.removeFirst()(); assert(clipboard.last == "texto")
        model.upload(); background.removeFirst()(); let failedURL = uploadURL!
        upload!(.failure(NSError(domain: "test", code: 1)))
        assert(!model.uploading && model.message.hasPrefix("Falhou:"))
        assert(!FileManager.default.fileExists(atPath: failedURL.deletingLastPathComponent().path))
        model.capture(); let (cancelledURL, done) = captures.removeFirst(); done(false)
        assert(model.image != nil && !model.capturing && !FileManager.default.fileExists(atPath: cancelledURL.deletingLastPathComponent().path))
        print("Capture model tests passed")
    }
}
