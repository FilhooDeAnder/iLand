import AppKit
import ApplicationServices

/// Captura com rolagem: tira um print da área, rola o conteúdo, tira outro, e cola os pedaços achando a sobreposição.
enum ScrollStitcher {
    /// Cinza com a largura reduzida (a altura fica inteira: o deslocamento precisa ser exato em pixels).
    struct Gray { let width: Int; let height: Int; let px: [UInt8] }

    static func gray(_ image: CGImage, columns: Int = 96) -> Gray? {
        guard let ctx = CGContext(data: nil, width: columns, height: image.height, bitsPerComponent: 8, bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        // A memória do CGContext começa pela linha de cima.
        let px = Array(UnsafeBufferPointer(start: bytes, count: columns * image.height))
        return Gray(width: columns, height: image.height, px: px)
    }

    /// Os dois quadros são iguais (a página não andou)? Diferença média por pixel abaixo de 0,6.
    static func identical(_ a: Gray, _ b: Gray) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        var sum = 0
        for i in stride(from: 0, to: a.px.count, by: 3) { sum += abs(Int(a.px[i]) - Int(b.px[i])) }
        return Double(sum) / Double(a.px.count / 3 + 1) < 0.6
    }

    /// Quantos pixels o conteúdo andou de `prev` para `cur` (0 = não andou). `expected` desempata áreas lisas.
    static func shift(prev: Gray, cur: Gray, expected: Int, minOverlap: Int = 24) -> (shift: Int, cost: Double)? {
        let h = prev.height, w = prev.width
        guard cur.height == h, cur.width == w, h > minOverlap * 2 else { return nil }
        var best = (shift: 0, cost: Double.infinity)
        for d in 0...(h - minOverlap) {
            var sum = 0, n = 0, i = 0
            while i < h - d {
                let p = (d + i) * w, c = i * w
                for x in 0..<w { sum += abs(Int(prev.px[p + x]) - Int(cur.px[c + x])) }
                n += w; i += 2
            }
            let cost = Double(sum) / Double(n) + 0.002 * Double(abs(d - expected))
            if cost < best.cost { best = (d, cost) }
        }
        return best
    }

    /// Une os quadros: o quadro k entra `shifts[k-1]` pixels mais embaixo que o anterior.
    static func compose(_ frames: [CGImage], shifts: [Int]) -> CGImage? {
        guard let first = frames.first, frames.count == shifts.count + 1 else { return nil }
        let w = first.width, h = first.height, total = h + shifts.reduce(0, +)
        guard let ctx = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var offset = 0
        for (k, frame) in frames.enumerated() {
            if k > 0 { offset += shifts[k - 1] }
            ctx.draw(frame, in: CGRect(x: 0, y: total - h - offset, width: w, height: h))
        }
        return ctx.makeImage()
    }
}

enum ScrollCapture {
    private static var cancelled = false

    /// `rect` em pontos, origem no canto superior esquerdo. Escreve o PNG final em `url`.
    static func run(rect: CGRect, to url: URL, _ done: @escaping (Bool) -> Void) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { Toast.show("Libere a Acessibilidade para o iLand (Ajustes do Sistema → Privacidade)."); return done(false) }
        cancelled = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { if $0.keyCode == 53 { cancelled = true } }
        let maxHeight = max(1000, Int(CapturePrefs.string(CapturePrefs.Key.scrollMax)) ?? 12000)
        let delay = 0.55 - 0.05 * Double(min(10, max(1, Int(CapturePrefs.string(CapturePrefs.Key.scrollSpeed)) ?? 5)))   // velocidade 1…10 → espera de 0,5 s a 0,05 s
        let sign: Int32 = CapturePrefs.bool(CapturePrefs.Key.scrollReverse) ? 1 : -1
        let region = ScreenCapture.rectArg(rect)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("scroll-step.png")
        var frames: [CGImage] = [], shifts: [Int] = [], grays: [ScrollStitcher.Gray] = []

        func finish() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            try? FileManager.default.removeItem(at: tmp)
            guard let image = ScrollStitcher.compose(frames, shifts: shifts), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil
            else { return done(false) }
            done(true)
        }
        func grab(_ next: @escaping (CGImage) -> Void) {
            try? FileManager.default.removeItem(at: tmp)
            ScreenTools.screencapture(["-x", "-R", region], to: tmp) { ok in
                guard ok, let data = try? Data(contentsOf: tmp), let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return finish() }
                next(image)
            }
        }
        func step() {
            guard !cancelled, frames[0].height + shifts.reduce(0, +) < maxHeight else { return finish() }
            let h = frames[0].height, scale = CGFloat(h) / rect.height
            let wheel = Int32(max(40, rect.height * 0.55))
            if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: sign * wheel, wheel2: 0, wheel3: 0) {
                ev.location = CGPoint(x: rect.midX, y: rect.midY); ev.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.25) {
                grab { image in
                    guard let g = ScrollStitcher.gray(image), let last = grays.last, !ScrollStitcher.identical(last, g),   // igual ao anterior: chegou ao fim
                          let m = ScrollStitcher.shift(prev: last, cur: g, expected: shifts.last ?? Int(CGFloat(wheel) * scale)),
                          m.shift > 1, m.cost < 14 else { return finish() }   // não andou (fim da página) ou não achou a sobreposição
                    frames.append(image); grays.append(g); shifts.append(m.shift)
                    step()
                }
            }
        }
        Toast.show("Rolando… (Esc para parar)", seconds: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            grab { first in
                guard let g = ScrollStitcher.gray(first) else { return finish() }
                frames = [first]; grays = [g]; step()
            }
        }
    }
}
