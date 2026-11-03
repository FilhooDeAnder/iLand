import AppKit
import Combine

/// Temperatura na barra de menus (substitui o MacTemp). Vira laranja com suspeitos e vermelha se o Mac está limitando o desempenho.
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var sink: AnyCancellable?
    private let onClick: () -> Void
    private let tools: ToolsModel
    private var toolsSink: AnyCancellable?
    private var last: SystemStats?
    private var lastKey = ""

    init(monitor: SystemMonitor, tools: ToolsModel, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.tools = tools
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.title = "--°C"
        sink = monitor.$stats.compactMap { $0 }.sink { [weak self] in self?.last = $0; self?.update($0) }
        toolsSink = Publishers.Merge3(tools.objectWillChange.map { _ in () }, tools.statusClock, tools.machines.objectWillChange.map { _ in () }).sink { [weak self] _ in
            DispatchQueue.main.async { if let self, let s = self.last { self.update(s) } }
        }
    }

    @objc private func clicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return onClick() }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Abrir iLand", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let prefs = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        if let r = Updater.shared.available {
            let up = NSMenuItem(title: "Atualizar para \(r.version)", action: #selector(installUpdate), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair do iLand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)   // mostra o menu; depois tira, para o clique esquerdo continuar abrindo o notch
        item.menu = nil
    }

    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc private func installUpdate() { Updater.shared.install(); SettingsWindow.shared.show(.about) }
    @objc private func openWindow() { MainWindow.shared.show(.assistant) }

    private func update(_ s: SystemStats) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let temp = s.cpuTemp > 0 ? "\(Int(s.cpuTemp))°C" : "--°C"
        let text = NSMutableAttributedString(string: temp, attributes: [.font: font])
        if s.thermalCritical {
            text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: text.length))
        }
        let issues = s.suspects.count + s.alerts.count + tools.machines.issueCount
        if issues > 0 {
            text.append(NSAttributedString(string: " · \(issues) ⚠",
                                           attributes: [.font: font, .foregroundColor: NSColor.systemOrange]))
        }
        if Prefs.string(Prefs.Key.timerWhere) != "ear", let t = tools.earText {
            text.append(NSAttributedString(string: " · \(t.value)", attributes: [.font: font]))
        }
        if tools.caffeine.isOn {
            text.append(NSAttributedString(string: " ☕", attributes: [.font: font]))
        }
        // Mexer no título do item de menu custa caro (relayout da barra): só quando o texto ou a cor mudou.
        let key = text.string + "|" + (s.thermalCritical ? "r" : "") + (issues == 0 ? "" : "o")
        guard key != lastKey else { return }
        lastKey = key
        item.button?.attributedTitle = text
    }
}
