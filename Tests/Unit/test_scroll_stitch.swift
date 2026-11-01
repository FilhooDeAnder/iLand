import AppKit

@main struct ScrollStitchTests {
    static func main() {
        func check(_ c: @autoclosure () -> Bool, _ m: String) { if !c() { fatalError(m) } }
        // Página alta com conteúdo variado (linhas com padrões diferentes, como texto e imagens).
        let w = 120, total = 1000, frameH = 400
        var rng = SystemRandomNumberGenerator()
        var page = [UInt8](repeating: 0, count: w * total * 4)
        for y in 0..<total {
            let band = UInt8.random(in: 0...255, using: &rng)
            for x in 0..<w {
                let o = (y * w + x) * 4
                let v = UInt8(truncatingIfNeeded: Int(band) &+ x &* (y % 7 + 1) &+ Int.random(in: 0...20, using: &rng))
                page[o] = v; page[o + 1] = UInt8(truncatingIfNeeded: Int(v) &* 3); page[o + 2] = UInt8(truncatingIfNeeded: y &* 5); page[o + 3] = 255
            }
        }
        func frame(_ offset: Int) -> CGImage {
            let slice = Array(page[(offset * w * 4)..<((offset + frameH) * w * 4)])
            return CGImage(width: w, height: frameH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(slice) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let offsets = [0, 310, 600]   // o último quadro encosta no fim da página (400 + 600 = 1000)
        let frames = offsets.map(frame)
        let grays = frames.map { ScrollStitcher.gray($0)! }
        let s1 = ScrollStitcher.shift(prev: grays[0], cur: grays[1], expected: 220)!
        let s2 = ScrollStitcher.shift(prev: grays[1], cur: grays[2], expected: 220)!
        check(s1.shift == 310 && s1.cost < 4, "first shift is found exactly (got \(s1.shift))")
        check(s2.shift == 290 && s2.cost < 4, "second shift is found exactly (got \(s2.shift))")
        let still = ScrollStitcher.shift(prev: grays[2], cur: grays[2], expected: 220)!
        check(still.shift <= 1, "same frame means the page did not move")
        let stitched = ScrollStitcher.compose(frames, shifts: [s1.shift, s2.shift])!
        check(stitched.width == w && stitched.height == total, "stitched height equals the page height")
        // confere pixel a pixel com a página original
        let ctx = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(stitched, in: CGRect(x: 0, y: 0, width: w, height: total))
        let out = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var wrong = 0
        for y in 0..<total { for x in 0..<w { let o = (y * w + x) * 4; if abs(Int(out[o]) - Int(page[o])) > 2 { wrong += 1 } } }
        check(wrong == 0, "stitched image matches the original page (\(wrong) pixels differ)")
        check(ScrollStitcher.identical(grays[2], grays[2]) && !ScrollStitcher.identical(grays[0], grays[1]), "identical detects the end of the page")
        check(ScrollStitcher.compose(frames, shifts: [1]) == nil, "bad shifts count is rejected")
        print("Scroll stitch tests passed")
    }
}
