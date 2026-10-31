import SwiftUI
import AppKit
import Carbon.HIToolbox

/// As ações com atalho global. Os padrões seguem o Shottr; vazio = sem atalho.
enum CaptureAction: String, CaseIterable, Identifiable {
    case area, fullscreen, window, anyWindow, repeatArea, scroll, ocr, showLast, openClipboard, library
    var id: String { rawValue }
    var title: String {
        switch self {
        case .area: "Captura de área"
        case .fullscreen: "Captura da tela inteira"
        case .window: "Captura da janela ativa"
        case .anyWindow: "Captura de qualquer janela"
        case .repeatArea: "Repetir a última área"
        case .scroll: "Captura com rolagem"
        case .ocr: "Texto ou QR code da tela"
        case .showLast: "Mostrar a última captura"
        case .openClipboard: "Abrir a imagem da área de transferência"
        case .library: "Abrir a biblioteca de capturas"
        }
    }
    var defaultsKey: String { "capHK_\(rawValue)" }
    /// ⌃⌥⌘ + número: não colide com os atalhos do macOS (⇧⌘3/4/5) nem com o Shottr (⇧⌘1…4, ⌃⌥⌘O).
    var defaultCombo: KeyCombo? {
        let all = UInt32(cmdKey | optionKey | controlKey)
        switch self {
        case .fullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: all)
        case .area: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: all)
        case .window: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: all)
        case .scroll: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: all)
        case .ocr: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: all)
        default: return nil
        }
    }
    var combo: KeyCombo? {
        guard let stored = UserDefaults.standard.string(forKey: defaultsKey) else { return defaultCombo }
        return KeyCombo(stored)   // "none" ou texto inválido = sem atalho
    }
    func setCombo(_ c: KeyCombo?) { UserDefaults.standard.set(c?.stored ?? "none", forKey: defaultsKey) }
}

/// Registra os atalhos globais da captura e refaz o registro quando a pessoa troca um deles.
enum CaptureHotKeys {
    private static var snapshot = ""
    private static var observer: NSObjectProtocol?

    static func start(model: CaptureModel) {
        apply(model)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in apply(model) }
    }

    private static func apply(_ model: CaptureModel) {
        let now = CaptureAction.allCases.map { "\($0.rawValue)=\($0.combo?.stored ?? "-")" }.joined(separator: ";")
        guard now != snapshot else { return }
        snapshot = now
        for (i, action) in CaptureAction.allCases.enumerated() {
            let id = UInt32(10 + i)
            guard let c = action.combo else { HotKey.unregister(id: id); continue }
            HotKey.register(id: id, keyCode: c.keyCode, modifiers: c.modifiers) { run(action, model) }
        }
    }

    static func run(_ action: CaptureAction, _ model: CaptureModel) {
        switch action {
        case .area: model.capture(.area)
        case .fullscreen: model.capture(.fullscreen)
        case .window: model.capture(.window)
        case .anyWindow: model.capture(.anyWindow)
        case .repeatArea: model.capture(.repeatArea)
        case .ocr: model.captureText()
        case .showLast: model.showLast()
        case .openClipboard: model.openClipboardImage()
        case .library: model.showLibrary()
        case .scroll: model.capture(.scroll)
        }
    }
}

/// Campo que grava um atalho: clique, digite a combinação. Esc cancela, ⌫ remove.
struct HotKeyField: View {
    let action: CaptureAction
    @State private var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    init(_ action: CaptureAction) { self.action = action; _combo = State(initialValue: action.combo) }

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "Digite o atalho…" : (combo?.label ?? "Sem atalho"))
                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(recording ? Theme.accent : (combo == nil ? Theme.textTertiary : Theme.textPrimary))
                .frame(width: 130)
                .padding(.vertical, 6)
                .glassSurface(cornerRadius: Theme.radiusRow)
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = KeyCombo.carbon(event.modifierFlags)
            switch Int(event.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete: assign(nil)
            default:
                let isFunctionKey = (kVK_F1...kVK_F12).contains(Int(event.keyCode))
                guard mods != 0 || isFunctionKey else { NSSound.beep(); return nil }
                assign(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
            }
            return nil
        }
    }

    private func assign(_ c: KeyCombo?) {
        if let c { for other in CaptureAction.allCases where other != action && other.combo == c { other.setCombo(nil) } }   // um atalho, uma ação
        action.setCombo(c); combo = c; stop()
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct CaptureSettings: View {
    typealias K = CapturePrefs.Key
    @AppStorage(K.afterArea) private var afterArea = "thumbnail"
    @AppStorage(K.show) private var show = true
    @AppStorage(K.copy) private var copy = false
    @AppStorage(K.save) private var save = false
    @AppStorage(K.thumbClose) private var thumbClose = "manual"
    @AppStorage(K.folder) private var folder = ""
    @AppStorage(K.format) private var format = "auto"
    @AppStorage(K.downscale) private var downscale = false
    @AppStorage(K.trimShadow) private var trimShadow = false
    @AppStorage(K.windowBg) private var windowBg = "transparent"
    @AppStorage(K.windowColor) private var windowColor = "#C4C6C8"
    @AppStorage(K.ocrLanguage) private var ocrLanguage = "pt-BR"
    @AppStorage(K.ocrBreaks) private var ocrBreaks = false
    @AppStorage(K.confirm) private var confirm = "custom"
    @AppStorage(K.esc) private var esc = "none"
    @AppStorage(K.zoom100) private var zoom100 = false
    @AppStorage(K.reverseZoom) private var reverseZoom = false
    @AppStorage(K.scrollMax) private var scrollMax = "12000"
    @AppStorage(K.scrollSpeed) private var scrollSpeed = "5"
    @AppStorage(K.scrollReverse) private var scrollReverse = false
    @AppStorage(K.deeplinks) private var deeplinks = false
    @State private var permitted = CGPreflightScreenCaptureAccess()

    private let languages = [("pt-BR", "Português (Brasil)"), ("en-US", "English"), ("es-ES", "Español"), ("fr-FR", "Français"), ("de-DE", "Deutsch"), ("it-IT", "Italiano")]

    var body: some View {
        SettingsPage(symbol: "camera.viewfinder", title: "Captura", subtitle: "Atalhos, o que acontece depois do print e onde salvar.") {
            GlassSection("Atalhos globais", footer: "Dois apps não podem usar o mesmo atalho. Para usar ⇧⌘3 ou ⇧⌘4, desligue-os em Ajustes do Sistema → Teclado → Atalhos → Capturas de tela. Se o Shottr estiver aberto, não repita os atalhos dele.") {
                ForEach(Array(CaptureAction.allCases.enumerated()), id: \.element) { i, a in
                    SettingRow(a.title, divider: i < CaptureAction.allCases.count - 1) { HotKeyField(a) }
                }
            }
            GlassSection("Depois da captura") {
                SettingRow("Mostrar") {
                    Picker("", selection: $afterArea) { Text("Miniatura").tag("thumbnail"); Text("Editor").tag("editor") }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                }
                SettingRow("Abrir a miniatura ou o editor") { Toggle("", isOn: $show).labelsHidden() }
                SettingRow("Copiar a imagem sozinho") { Toggle("", isOn: $copy).labelsHidden() }
                SettingRow("Salvar na pasta sozinho") { Toggle("", isOn: $save).labelsHidden() }
                SettingRow("Fechar a miniatura", divider: false) {
                    Picker("", selection: $thumbClose) { Text("Pelo botão X").tag("manual"); Text("Sozinha (clique fora)").tag("outside") }
                        .labelsHidden().frame(width: 190)
                }
            }
            GlassSection("Salvar") {
                SettingRow("Pasta", detail: folder.isEmpty ? "Mesa (padrão)" : folder) {
                    Button("Escolher…") { chooseFolder() }.glassButton()
                }
                SettingRow("Formato") {
                    Picker("", selection: $format) { Text("Automático (PNG ou JPEG)").tag("auto"); Text("PNG").tag("png"); Text("JPEG").tag("jpeg") }
                        .labelsHidden().frame(width: 220)
                }
                SettingRow("Reduzir Retina para 1× ao salvar") { Toggle("", isOn: $downscale).labelsHidden() }
                SettingRow("Captura de janela sem a sombra") { Toggle("", isOn: $trimShadow).labelsHidden() }
                SettingRow("Fundo da captura de janela", divider: windowBg == "solid") {
                    Picker("", selection: $windowBg) { Text("Transparente").tag("transparent"); Text("Papel de parede").tag("wallpaper"); Text("Cor sólida").tag("solid") }
                        .labelsHidden().frame(width: 190)
                }
                if windowBg == "solid" { SettingRow("Cor", detail: "Formato #RRGGBB.", divider: false) { GlassField(placeholder: "#C4C6C8", text: $windowColor, width: 120) } }
            }
            UploadSettings()
            GlassSection("Texto da tela (OCR)") {
                SettingRow("Idioma principal") {
                    Picker("", selection: $ocrLanguage) { ForEach(languages, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 190)
                }
                SettingRow("Tirar as quebras de linha", divider: false) { Toggle("", isOn: $ocrBreaks).labelsHidden() }
            }
            GlassSection("Editor") {
                SettingRow("Ao fechar com Esc") {
                    Picker("", selection: $esc) { Text("Só fechar").tag("none"); Text("Copiar a imagem").tag("copy"); Text("Salvar a imagem").tag("save") }
                        .labelsHidden().frame(width: 190)
                }
                SettingRow("Abrir sempre em 100%") { Toggle("", isOn: $zoom100).labelsHidden() }
                SettingRow("Inverter o zoom da roda do mouse", detail: "O zoom é ⌘ + roda.") { Toggle("", isOn: $reverseZoom).labelsHidden() }
                SettingRow("Aviso de confirmação", divider: false) {
                    Picker("", selection: $confirm) { Text("Do iLand").tag("custom"); Text("Do sistema").tag("system"); Text("Nenhum").tag("none") }
                        .labelsHidden().frame(width: 190)
                }
            }
            GlassSection("Captura com rolagem", footer: "Precisa da permissão de Acessibilidade. Esc para no meio e usa o que já foi capturado.") {
                SettingRow("Altura máxima") {
                    Picker("", selection: $scrollMax) { ForEach(["6000", "12000", "20000", "30000"], id: \.self) { Text("\($0) px").tag($0) } }.labelsHidden().frame(width: 130)
                }
                SettingRow("Velocidade", detail: "Menor = espera mais entre as rolagens (use em páginas lentas).") {
                    Picker("", selection: $scrollSpeed) { ForEach(1...10, id: \.self) { Text("\($0)").tag(String($0)) } }.labelsHidden().frame(width: 130)
                }
                SettingRow("Inverter a direção da rolagem", divider: false) { Toggle("", isOn: $scrollReverse).labelsHidden() }
            }
            GlassSection("Integração", footer: "Exemplo: iland://grab/area?then=editor. Ações: area, fullscreen, window, anywindow, repeat, scroll, ocr. Também iland://open/library.") {
                SettingRow("Deep links (iland://)") { Toggle("", isOn: $deeplinks).labelsHidden() }
                SettingRow("Biblioteca de capturas", divider: false) { Button("Abrir") { MainWindow.shared.tools?.capture.showLibrary() }.glassButton() }
            }
            GlassSection("Permissão") {
                SettingRow("Gravação de tela", detail: permitted ? "Liberada." : "O macOS ainda não liberou. Sem ela o print sai em branco.", divider: false) {
                    HStack(spacing: 8) {
                        StatusPill(text: permitted ? "ok" : "falta liberar", kind: permitted ? .ok : .warn)
                        Button("Abrir Ajustes") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }.glassButton()
                    }
                }
            }
        }
        .onAppear { permitted = CGPreflightScreenCaptureAccess() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Escolher"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
