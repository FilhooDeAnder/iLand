import AppKit
import Carbon.HIToolbox

@main struct CaptureOutputTests {
    static func main() throws {
        func check(_ c: @autoclosure () -> Bool, _ m: String) { if !c() { fatalError(m) } }
        func rep(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> [UInt8]) -> Data {
            let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<h { for x in 0..<w { let p = pixel(x, y); for i in 0..<4 { r.bitmapData![y * r.bytesPerRow + x * 4 + i] = p[i] } } }
            return r.representation(using: .png, properties: [:])!
        }
        let flat = rep(200, 100) { x, _ in x < 100 ? [255, 255, 255, 255] : [20, 20, 20, 255] }
        let noisy = rep(200, 100) { x, y in [UInt8(x * 255 / 200), UInt8(y * 255 / 100), UInt8(((x + y) * 255 / 300 + (x * y) % 9) % 256), 255] }
        check(CaptureOutput.resolve("auto", png: flat) == .png, "UI-like image stays PNG")
        check(CaptureOutput.resolve("auto", png: noisy) == .jpeg, "photo-like image becomes JPEG")
        check(CaptureOutput.resolve("png", png: noisy) == .png && CaptureOutput.resolve("jpeg", png: flat) == .jpeg, "explicit format wins")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iland-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try CaptureOutput.save(flat, to: dir, formatPref: "png", downscaleBy: 1, date: date)
        let b = try CaptureOutput.save(flat, to: dir, formatPref: "png", downscaleBy: 1, date: date)
        check(a != b && a.lastPathComponent.hasPrefix("Screenshot ") && b.lastPathComponent.hasSuffix(" 2.png"), "never overwrites")
        let half = try CaptureOutput.save(flat, to: dir, formatPref: "png", downscaleBy: 2, date: date)
        let size = NSBitmapImageRep(data: try Data(contentsOf: half))!
        check(size.pixelsWide == 100 && size.pixelsHigh == 50, "Retina downscale halves the pixels")
        let jpg = try CaptureOutput.save(noisy, to: dir, formatPref: "jpeg", downscaleBy: 1, date: date)
        let jpgData = try Data(contentsOf: jpg)
        check(jpg.pathExtension == "jpg" && NSBitmapImageRep(data: jpgData) != nil, "JPEG file decodes")

        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: KeyCombo.carbon([.command, .shift]))
        check(KeyCombo(combo.stored) == combo && combo.label == "⇧⌘2", "key combo round trip and label")
        check(KeyCombo("lixo") == nil, "bad stored combo is rejected")
        // fundo da captura de janela: transparente fica como está, sólido pinta atrás
        let windowPNG = rep(40, 40) { x, y in (10..<30).contains(x) && (10..<30).contains(y) ? [255, 0, 0, 255] : [0, 0, 0, 0] }
        let file = dir.appendingPathComponent("win.png"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try windowPNG.write(to: file)
        UserDefaults.standard.set("transparent", forKey: CapturePrefs.Key.windowBg)
        check(WindowBackground.apply(to: file), "transparent mode succeeds")
        let untouched = NSBitmapImageRep(data: try Data(contentsOf: file))!
        check(untouched.colorAt(x: 2, y: 2)!.alphaComponent == 0, "transparent mode keeps the corner clear")
        UserDefaults.standard.set("solid", forKey: CapturePrefs.Key.windowBg); UserDefaults.standard.set("#00FF00", forKey: CapturePrefs.Key.windowColor)
        check(WindowBackground.apply(to: file), "solid mode succeeds")
        let painted = NSBitmapImageRep(data: try Data(contentsOf: file))!
        let corner = painted.colorAt(x: 2, y: 2)!.usingColorSpace(.sRGB)!, center = painted.colorAt(x: 20, y: 20)!.usingColorSpace(.sRGB)!
        check(corner.alphaComponent > 0.99 && corner.greenComponent > 0.9 && corner.redComponent < 0.1, "solid mode paints the corner green")
        check(center.redComponent > 0.8 && center.greenComponent < 0.35, "the window stays on top")
        check(WindowBackground.color(hex: "#C4C6C8") != nil && WindowBackground.color(hex: "xyz") == nil, "hex parsing")
        UserDefaults.standard.removeObject(forKey: CapturePrefs.Key.windowBg); UserDefaults.standard.removeObject(forKey: CapturePrefs.Key.windowColor)
        print("Capture output tests passed")
    }
}
