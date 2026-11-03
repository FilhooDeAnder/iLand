// Ajudante do scripts/readme_shots.sh.
//   window <pid>                 imprime o id da maior janela do processo (o notch)
//   frame <ilha.png> <saida.png> põe a ilha sobre um fundo com barra de menus, para o README
import AppKit

let a = CommandLine.arguments
if a.count == 3, a[1] == "window", let pid = Int(a[2]) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
    func area(_ w: [String: Any]) -> CGFloat {
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    if let w = mine.max(by: { area($0) < area($1) }), let id = w[kCGWindowNumber as String] as? Int { print(id) } else { exit(1) }
} else if a.count == 4, a[1] == "frame", let full = NSImage(contentsOfFile: a[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    // A janela é mais alta que a forma (cabe qualquer estado): corta as linhas transparentes de baixo.
    let ctx = CGContext(data: nil, width: full.width, height: full.height, bitsPerComponent: 8, bytesPerRow: full.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(full, in: CGRect(x: 0, y: 0, width: full.width, height: full.height))
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var rows = full.height   // linhas do topo até a última com algum pixel visível
    while rows > 1, !(0..<full.width).contains(where: { px[(rows - 1) * full.width * 4 + $0 * 4 + 3] > 8 }) { rows -= 1 }
    let crop = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: rows))!
    let island = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    let w = CGFloat(crop.width), h = CGFloat(crop.height)
    let side: CGFloat = 160, bottom: CGFloat = 120, bar: CGFloat = 74   // pixels (2x)
    let W = max(w + 2 * side, 1400), H = h + bottom
    let out = NSImage(size: NSSize(width: W, height: H))
    out.lockFocus()
    NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.42, alpha: 1), NSColor(red: 0.45, green: 0.30, blue: 0.55, alpha: 1),
                        NSColor(red: 0.93, green: 0.55, blue: 0.45, alpha: 1)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
    NSColor.white.withAlphaComponent(0.18).setFill()
    NSRect(x: 0, y: H - bar, width: W, height: bar).fill()
    island.draw(in: NSRect(x: (W - w) / 2, y: H - h, width: w, height: h))
    out.unlockFocus()
    guard let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: URL(fileURLWithPath: a[3]))
} else {
    FileHandle.standardError.write(Data("uso: window <pid> | frame <ilha.png> <saida.png>\n".utf8)); exit(2)
}
