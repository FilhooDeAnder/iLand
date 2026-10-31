import AppKit

@main struct CaptureEditorTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
        func color(_ image: NSImage, _ x: Int, _ y: Int) -> NSColor {
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            return rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)!.usingColorSpace(.deviceRGB)!
        }
        func near(_ a: NSColor, _ b: NSColor, _ t: CGFloat = 0.06) -> Bool {
            abs(a.redComponent - b.redComponent) < t && abs(a.greenComponent - b.greenComponent) < t && abs(a.blueComponent - b.blueComponent) < t
        }
        func px(_ image: NSImage) -> (Int, Int) { let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!; return (cg.width, cg.height) }
        func canvas(_ w: Int = 200, _ h: Int = 100, fill: UInt8 = 255) -> CaptureEditorCanvas {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            memset(rep.bitmapData!, Int32(fill), rep.bytesPerRow * rep.pixelsHigh)
            let image = NSImage(size: NSSize(width: w / 2, height: h / 2)); image.addRepresentation(rep)
            return CaptureEditorCanvas(image: image)!
        }
        func isRed(_ c: NSColor) -> Bool { c.redComponent > 0.85 && c.greenComponent < 0.55 && c.blueComponent < 0.55 }
        let white = NSColor.white.usingColorSpace(.deviceRGB)!
        let e = canvas()
        check(px(e.image) == (200, 100) && !e.dirty, "Retina source keeps its pixels, clean start")

        e.add(e.makeAnnotation(.rectangle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 100, y: 70)))
        check(e.dirty && isRed(color(e.image, 20, 45)), "rectangle border drawn")
        check(near(color(e.image, 60, 45), white) && near(color(e.image, 150, 45), white), "rectangle interior/exterior untouched")
        e.add(e.makeAnnotation(.arrow, from: NSPoint(x: 120, y: 20), to: NSPoint(x: 180, y: 20)))
        check(isRed(color(e.image, 150, 20)), "arrow shaft drawn")
        e.add(e.makeAnnotation(.oval, from: NSPoint(x: 110, y: 40), to: NSPoint(x: 190, y: 90)))
        check(isRed(color(e.image, 110, 65)), "oval edge drawn")
        e.add(e.makeAnnotation(.line, from: NSPoint(x: 5, y: 95), to: NSPoint(x: 95, y: 95)))
        check(isRed(color(e.image, 50, 95)), "line drawn")
        var pen = e.makeAnnotation(.freehand, from: NSPoint(x: 10, y: 5), to: NSPoint(x: 90, y: 5)); pen.path = [NSPoint(x: 10, y: 5), NSPoint(x: 50, y: 5), NSPoint(x: 90, y: 5)]
        e.add(pen); check(isRed(color(e.image, 50, 5)), "freehand drawn")
        e.add(e.makeAnnotation(.counter, from: NSPoint(x: 30, y: 85), to: NSPoint(x: 30, y: 85)))
        e.add(e.makeAnnotation(.counter, from: NSPoint(x: 60, y: 85), to: NSPoint(x: 60, y: 85)))
        check(e.annotations.suffix(2).map(\.number) == [1, 2], "counters are numbered in sequence")
        check(isRed(color(e.image, 30, 85 - 8)), "counter disc drawn")
        var label = e.makeAnnotation(.text, from: NSPoint(x: 120, y: 98), to: NSPoint(x: 120, y: 98)); label.text = "Oi"
        e.add(label); check(label.bounds.width > 5 && label.bounds.height > 5, "text has a size")

        let h = canvas()
        h.colors[.highlight] = .systemYellow; h.color = .systemYellow
        h.add(h.makeAnnotation(.highlight, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 80, y: 60)))
        let tint = color(h.image, 50, 40)
        check(tint.redComponent > 0.9 && tint.blueComponent < 0.8 && near(color(h.image, 100, 40), white), "highlight tints only its area")

        do {
            let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<100 { for x in 0..<100 { let o = y * r.bytesPerRow + x * 4; let v: UInt8 = (x / 2) % 2 == 0 ? 0 : 255; r.bitmapData![o] = v; r.bitmapData![o+1] = v; r.bitmapData![o+2] = v; r.bitmapData![o+3] = 255 } }
            let img = NSImage(size: NSSize(width: 100, height: 100)); img.addRepresentation(r)
            let c = CaptureEditorCanvas(image: img)!
            c.color = .black
            c.add(c.makeAnnotation(.blur, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 80, y: 80)))
            let inside = [30, 31, 32, 33, 34, 35].map { color(c.image, $0, 50).redComponent }
            check((inside.max()! - inside.min()!) < 0.3, "blur flattens the stripes inside the area")
            check(color(c.image, 5, 50).redComponent != color(c.image, 7, 50).redComponent, "blur leaves the outside alone")
            c.undoEdit(); check(color(c.image, 31, 50).redComponent != color(c.image, 33, 50).redComponent, "undo removes the blur")
            c.redoEdit()
            check(abs(color(c.image, 31, 50).redComponent - color(c.image, 33, 50).redComponent) < 0.3, "redo restores pixelation")

            // An off-center area must sample its own rows, not the vertically mirrored area.
            for y in 0..<100 { for x in 0..<100 {
                let o = y * r.bytesPerRow + x * 4
                r.bitmapData![o] = y < 50 ? 255 : 0
                r.bitmapData![o+1] = 0
                r.bitmapData![o+2] = y < 50 ? 0 : 255
            } }
            let asymmetric = NSImage(size: NSSize(width: 100, height: 100)); asymmetric.addRepresentation(r)
            let vertical = CaptureEditorCanvas(image: asymmetric)!
            vertical.add(vertical.makeAnnotation(.blur, from: NSPoint(x: 20, y: 60), to: NSPoint(x: 80, y: 90)))
            check(isRed(color(vertical.image, 40, 75)), "pixelation samples the selected rows")
            check(near(color(vertical.image, 40, 25), .blue, 0.25), "pixelation preserves the opposite rows")
        }

        // desfazer, refazer, mover, apagar
        let u = canvas()
        u.add(u.makeAnnotation(.rectangle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 100, y: 70)))
        u.undoEdit(); check(near(color(u.image, 20, 45), white) && u.annotations.isEmpty, "undo removes rectangle")
        u.redoEdit(); check(isRed(color(u.image, 20, 45)), "redo restores rectangle")
        u.undoEdit(); u.add(u.makeAnnotation(.line, from: NSPoint(x: 5, y: 5), to: NSPoint(x: 50, y: 5)))
        check(!u.canRedo, "new edit discards redo")
        var moved = u.makeAnnotation(.rectangle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 40, y: 40)); moved.move(by: NSSize(width: 10, height: 5))
        check(moved.a == NSPoint(x: 30, y: 25) && moved.b == NSPoint(x: 50, y: 45), "move shifts the points")

        // recortar mantém a orientação e junta os objetos
        let rep2 = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<60 { for x in 0..<80 {
            let rgba: [UInt8] = y < 30 ? (x < 40 ? [255, 0, 0, 255] : [0, 255, 0, 255]) : (x < 40 ? [0, 0, 255, 255] : [255, 255, 0, 255])
            for i in 0..<4 { rep2.bitmapData![y * rep2.bytesPerRow + x * 4 + i] = rgba[i] }
        } }
        let src = NSImage(size: NSSize(width: 40, height: 30)); src.addRepresentation(rep2)
        let crop = CaptureEditorCanvas(image: src)!
        crop.crop(to: NSRect(x: 10, y: 5, width: 50, height: 40))
        check(px(crop.image) == (50, 40), "crop uses pixel dimensions")
        check(near(color(crop.image, 5, 5), .blue, 0.25) && near(color(crop.image, 45, 5), .yellow, 0.25), "crop bottom orientation")
        check(near(color(crop.image, 5, 35), .red, 0.25) && near(color(crop.image, 45, 35), .green, 0.25), "crop top orientation")
        crop.undoEdit(); check(px(crop.image) == (80, 60), "undo restores size")
        crop.redoEdit(); check(px(crop.image) == (50, 40), "redo restores crop")

        // holofote: escurece fora, mantém dentro
        let sp = canvas()
        sp.add(sp.makeAnnotation(.spotlight, from: NSPoint(x: 50, y: 25), to: NSPoint(x: 150, y: 75)))
        check(near(color(sp.image, 100, 50), white) && color(sp.image, 10, 10).redComponent < 0.6, "spotlight dims outside only")
        // preenchimento, tracejado, seta cheia, opacidade
        let f = canvas(); f.fill = true
        f.add(f.makeAnnotation(.rectangle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 100, y: 70)))
        check(isRed(color(f.image, 60, 45)), "fill paints the interior")
        let dsh = canvas(); dsh.dashed = true; dsh.sizeSetting = 3
        dsh.add(dsh.makeAnnotation(.line, from: NSPoint(x: 5, y: 50), to: NSPoint(x: 195, y: 50)))
        let samples = (5..<195).map { isRed(color(dsh.image, $0, 50)) }
        check(samples.contains(true) && samples.contains(false), "dashed line has gaps")
        let op = canvas(); op.opacity = 0.5
        op.add(op.makeAnnotation(.rectangle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 100, y: 70)))
        check(color(op.image, 20, 45).greenComponent > 0.5 && !near(color(op.image, 20, 45), white), "opacity lets the image show through")
        let ar = canvas(); ar.arrowStyle = .filled; ar.sizeSetting = 3
        ar.add(ar.makeAnnotation(.arrow, from: NSPoint(x: 20, y: 50), to: NSPoint(x: 180, y: 50)))
        check(isRed(color(ar.image, 172, 50 - 4)) && isRed(color(ar.image, 172, 50 + 4)), "filled arrow head is solid")
        // régua desenha linha e rótulo
        let ru = canvas(); ru.add(ru.makeAnnotation(.ruler, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 180, y: 20)))
        check(isRed(color(ru.image, 60, 20)), "ruler draws its line")
        // lupa mostra o centro ampliado
        let mg = canvas(fill: 255)
        do {
            let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<100 { for x in 0..<100 { let o = y * r.bytesPerRow + x * 4; let on = (48..<52).contains(x) && (48..<52).contains(y); r.bitmapData![o] = on ? 0 : 255; r.bitmapData![o+1] = on ? 0 : 255; r.bitmapData![o+2] = on ? 0 : 255; r.bitmapData![o+3] = 255 } }
            let img = NSImage(size: NSSize(width: 100, height: 100)); img.addRepresentation(r)
            let c = CaptureEditorCanvas(image: img)!
            c.add(c.makeAnnotation(.magnifier, from: NSPoint(x: 10, y: 10), to: NSPoint(x: 90, y: 90)))
            let dark = (0..<100).filter { color(c.image, $0, 50).redComponent < 0.3 }
            check(dark.count >= 6, "magnifier enlarges the center (2×)")
        }
        _ = mg
        // cor sob o mouse e redimensionar
        let cs = canvas(); check(CaptureEditorCanvas.hex(cs.color(at: NSPoint(x: 10, y: 10))!) == "#FFFFFF", "hex of the pixel")
        let rz = canvas(); rz.add(rz.makeAnnotation(.rectangle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 100, y: 70)))
        rz.resize(to: CGSize(width: 100, height: 50))
        check(px(rz.image) == (100, 50) && rz.annotations[0].b == NSPoint(x: 50, y: 35), "resize scales image and objects")
        rz.undoEdit(); check(px(rz.image) == (200, 100), "undo restores the size")

        // fundo: tamanho, gradiente, imagem no centro, sombra, proporção
        let bd = canvas()
        bd.backdrop.enabled = true; bd.backdrop.padding = 0.1; bd.backdrop.shadow = 0; bd.backdrop.innerRadius = 0
        bd.backdrop.colors = [NSColor.blue, NSColor.blue]
        check(px(bd.image) == (240, 140), "backdrop adds the padding on each side")
        check(near(color(bd.image, 120, 70), white) && near(color(bd.image, 3, 3), .blue, 0.25), "image in the center, gradient around")
        bd.add(bd.makeAnnotation(.rectangle, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 100, y: 70)))
        check(isRed(color(bd.image, 20 + 20, 20 + 45)), "annotations land inside the framed image")
        bd.backdrop.aspect = 1
        check(px(bd.image) == (240, 240), "aspect ratio widens the shorter side")
        let sh = canvas(); sh.backdrop.enabled = true; sh.backdrop.shadow = 1; sh.backdrop.colors = [.white, .white]
        check(color(sh.image, 120, 5).redComponent < 0.99 || color(sh.image, 120, 12).redComponent < 0.99, "shadow darkens the background near the image")
        var rv = Backdrop(); rv.colors = [.red, .blue]; rv.reverse(); check(rv.colors == [.blue, .red], "reverse swaps the colors")
        check(Backdrop().layout(for: CGSize(width: 50, height: 40)).size == CGSize(width: 50, height: 40), "disabled backdrop keeps the size")
        bd.backdrop.enabled = false; check(px(bd.image) == (200, 100), "turning the backdrop off restores the size")

        // captura adicionada: entra no centro, aparece na composição, redimensiona e desfaz
        let pc = canvas()
        let blue = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<20 { for x in 0..<40 { let o = y * blue.bytesPerRow + x * 4; blue.bitmapData![o] = 0; blue.bitmapData![o+1] = 0; blue.bitmapData![o+2] = 255; blue.bitmapData![o+3] = 255 } }
        let bluePic = NSImage(size: NSSize(width: 40, height: 20)); bluePic.addRepresentation(blue)
        pc.addPicture(bluePic.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        check(pc.annotations.count == 1 && pc.annotations[0].tool == .picture, "picture becomes an object")
        check(color(pc.image, 100, 50).blueComponent > 0.9 && color(pc.image, 100, 50).redComponent < 0.3, "picture is drawn in the center")
        check(near(color(pc.image, 5, 5), white), "picture does not touch the corners")
        pc.undoEdit(); check(pc.annotations.isEmpty && near(color(pc.image, 100, 50), white), "undo removes the picture")

        let png = NSBitmapImageRep(data: e.image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        check(px(NSImage(data: png)!) == (200, 100), "PNG export keeps dimensions")
        e.markApplied(); check(!e.dirty, "markApplied clears dirty")
        print("Capture editor tests passed")
    }
}
