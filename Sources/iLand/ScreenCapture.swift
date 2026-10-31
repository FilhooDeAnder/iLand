import AppKit
import CoreGraphics

enum CaptureMode: String, CaseIterable {
    case area, fullscreen, window, anyWindow, repeatArea, scroll
}

/// Os modos de captura do iLand. Todos entregam um arquivo PNG em `url`.
enum ScreenCapture {
    static func run(_ mode: CaptureMode, delay: Int = 0, to url: URL, _ done: @escaping (Bool) -> Void) {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let trim = CapturePrefs.bool(CapturePrefs.Key.trimShadow)
        func after(_ work: @escaping () -> Void) {
            guard delay > 0 else { return work() }
            Toast.show("Capturando em \(delay) s…", seconds: Double(delay))
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay), execute: work)
        }
        func region(_ r: CGRect) { after { ScreenTools.screencapture(["-x", "-R", rectArg(r)], to: url, done) } }
        switch mode {
        case .area:
            AreaSelector.pick { rect in
                guard let rect else { return done(false) }
                CapturePrefs.lastRect = rect
                region(rect)
            }
        case .scroll:
            AreaSelector.pick { rect in
                guard let rect else { return done(false) }
                CapturePrefs.lastRect = rect
                ScrollCapture.run(rect: rect, to: url, done)
            }
        case .repeatArea:
            guard let rect = CapturePrefs.lastRect else { Toast.show("Capture uma área antes de repetir."); return done(false) }
            region(rect)
        case .fullscreen:
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return done(false) }
            region(topLeft(screen.frame))
        case .window:
            guard let id = frontWindowID() else { Toast.show("Não achei a janela ativa."); return done(false) }
            after { ScreenTools.screencapture(["-x", "-l", String(id)] + (trim ? ["-o"] : []), to: url) { ok in done(ok && WindowBackground.apply(to: url)) } }
        case .anyWindow:
            after { ScreenTools.screencapture(["-i", "-w", "-x"] + (trim ? ["-o"] : []), to: url) { ok in done(ok && WindowBackground.apply(to: url)) } }
        }
    }

    /// Cocoa tem a origem embaixo à esquerda; o `screencapture -R` usa o canto superior esquerdo da tela principal.
    static func topLeft(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY, width: frame.width, height: frame.height)
    }

    static func rectArg(_ r: CGRect) -> String { "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))" }

    /// A janela da frente do app ativo (nunca uma do próprio iLand).
    static func frontWindowID() -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        let candidates = list.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) != own
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 40
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pick = candidates.first { ($0[kCGWindowOwnerPID as String] as? Int32) == front } ?? candidates.first
        return (pick?[kCGWindowNumber as String] as? Int).map { CGWindowID($0) }
    }
}
