import AppKit

/// Painel "Fundo" do editor: liga o fundo e ajusta gradiente, margem, sombra, cantos e proporção.
final class BackdropPanel: NSViewController {
    private let canvas: CaptureEditorCanvas
    private let enable = NSButton(checkboxWithTitle: "Usar fundo", target: nil, action: nil)
    private let preset = NSPopUpButton()
    private let aspect = NSPopUpButton()
    private let kind = NSSegmentedControl(labels: ["Linear", "Radial"], trackingMode: .selectOne, target: nil, action: nil)
    private var sliders: [String: NSSlider] = [:]

    init(canvas: CaptureEditorCanvas) { self.canvas = canvas; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    private func slider(_ key: String, _ title: String, _ range: ClosedRange<Double>, _ value: Double) -> NSStackView {
        let s = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(changed))
        s.widthAnchor.constraint(equalToConstant: 210).isActive = true
        sliders[key] = s
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, s]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 2
        return row
    }

    override func loadView() {
        let b = canvas.backdrop
        enable.state = b.enabled ? .on : .off; enable.target = self; enable.action = #selector(changed)
        Backdrop.presets.forEach { preset.addItem(withTitle: $0.name) }
        preset.addItem(withTitle: "Personalizado")
        preset.selectItem(at: Backdrop.presets.firstIndex { $0.colors == b.colors } ?? Backdrop.presets.count)
        preset.target = self; preset.action = #selector(pickPreset)
        Backdrop.aspects.forEach { aspect.addItem(withTitle: $0.0) }
        aspect.selectItem(at: Backdrop.aspects.firstIndex { $0.1 == b.aspect } ?? 0)
        aspect.target = self; aspect.action = #selector(changed)
        kind.selectedSegment = b.radial ? 1 : 0; kind.target = self; kind.action = #selector(changed)
        let reverse = NSButton(title: "Inverter", target: self, action: #selector(reverse))
        let random = NSButton(title: "Aleatório", target: self, action: #selector(randomize))
        let colors = NSStackView(views: [preset, reverse, random]); colors.spacing = 6
        func label(_ t: String) -> NSTextField { let l = NSTextField(labelWithString: t); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; return l }
        let stack = NSStackView(views: [enable, label("Gradiente"), colors, kind,
                                        slider("angle", "Ângulo", 0...360, Double(b.angle)),
                                        slider("padding", "Margem", 0...0.4, Double(b.padding)),
                                        slider("shadow", "Sombra", 0...1, Double(b.shadow)),
                                        slider("inner", "Cantos da imagem", 0...0.08, Double(b.innerRadius)),
                                        slider("outer", "Cantos do fundo", 0...0.08, Double(b.outerRadius)),
                                        label("Proporção"), aspect])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.frame.size = stack.fittingSize
        view = stack
    }

    @objc private func pickPreset() {
        guard preset.indexOfSelectedItem < Backdrop.presets.count else { return }
        canvas.backdrop.colors = Backdrop.presets[preset.indexOfSelectedItem].colors
        canvas.backdrop.enabled = true; enable.state = .on
    }
    @objc private func reverse() { canvas.backdrop.reverse(); canvas.backdrop.enabled = true; enable.state = .on; preset.selectItem(at: Backdrop.presets.count) }
    @objc private func randomize() {
        canvas.backdrop.randomize(); canvas.backdrop.enabled = true; enable.state = .on
        preset.selectItem(at: Backdrop.presets.count); sliders["angle"]?.doubleValue = Double(canvas.backdrop.angle)
    }
    @objc private func changed() {
        var b = canvas.backdrop
        b.enabled = enable.state == .on
        b.radial = kind.selectedSegment == 1
        b.angle = CGFloat(sliders["angle"]?.doubleValue ?? 45)
        b.padding = CGFloat(sliders["padding"]?.doubleValue ?? 0.08)
        b.shadow = CGFloat(sliders["shadow"]?.doubleValue ?? 0.5)
        b.innerRadius = CGFloat(sliders["inner"]?.doubleValue ?? 0)
        b.outerRadius = CGFloat(sliders["outer"]?.doubleValue ?? 0)
        b.aspect = Backdrop.aspects[max(0, aspect.indexOfSelectedItem)].1
        canvas.backdrop = b
    }
}
