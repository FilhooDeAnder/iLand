import SwiftUI

/// Tokens e peças de interface das janelas do iLand (configuração inicial e Ajustes): Liquid Glass no macOS 26+,
/// material translúcido antes disso. As views usam só estes nomes, nunca cor ou medida solta.
enum Theme {
    // Cores do próprio macOS: o acento é o que a pessoa escolheu em Ajustes do Sistema › Aparência.
    static let canvas = Color(white: 0.085)
    static let accent = Color.accentColor
    static let warning = Color(nsColor: .systemOrange)
    static let ok = Color(nsColor: .systemGreen)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.42)
    static let hairline = Color.white.opacity(0.08)

    // Medidas
    static let radiusCard: CGFloat = 22
    static let radiusRow: CGFloat = 14
    static let gutter: CGFloat = 28
    static let gap: CGFloat = 14

    // Tipografia: saltos grandes de tamanho e de peso.
    static let display = Font.system(size: 44, weight: .heavy, design: .rounded)
    static let title = Font.system(size: 30, weight: .bold, design: .rounded)
    static let lead = Font.system(size: 15, weight: .light)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11.5)
    static let overline = Font.system(size: 11, weight: .semibold)
}

/// Fundo neutro como o do notch: quase preto, com uma luz branca bem fraca no topo (o vidro precisa de algo atrás).
struct AtmosphereBackground: View {
    var body: some View {
        ZStack {
            Theme.canvas
            LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Superfície de vidro com cantos arredondados.
    @ViewBuilder func glassSurface(cornerRadius: CGFloat = Theme.radiusCard, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let g: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? g.interactive() : g, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    /// Botão de vidro. `prominent` = a ação principal da tela (uma por tela).
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent).tint(Theme.accent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent).tint(Theme.accent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// Agrupa vidros vizinhos (eles se fundem quando se aproximam).
    @ViewBuilder func glassGroup(spacing: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

/// Ícone de seção num círculo de vidro. Sem cor por padrão; `tint` só para estado (ok, aviso).
struct GlassIcon: View {
    let symbol: String
    var size: CGFloat = 44
    var tint: Color? = nil
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint ?? Theme.textPrimary)
            .frame(width: size, height: size)
            .glassSurface(cornerRadius: size / 2, tint: tint?.opacity(0.2))
    }
}

/// Cabeçalho de página: ícone, título grande e linha de apoio leve.
struct PageHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            GlassIcon(symbol: symbol, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.title).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(Theme.lead).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Cartão de vidro com título pequeno em cima e as linhas dentro.
struct GlassSection<Content: View>: View {
    let title: String?
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.footer = footer; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title.uppercased()).font(Theme.overline).kerning(0.6).foregroundStyle(Theme.textTertiary).padding(.leading, 6) }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.vertical, 6).padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface()
            if let footer { Text(footer).font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(.horizontal, 6).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Uma linha: rótulo (e detalhe) à esquerda, controle à direita. `divider` = linha fina embaixo.
struct SettingRow<Control: View>: View {
    let label: String
    var detail: String? = nil
    var symbol: String? = nil
    var divider = true
    @ViewBuilder let control: () -> Control

    init(_ label: String, detail: String? = nil, symbol: String? = nil, divider: Bool = true, @ViewBuilder control: @escaping () -> Control) {
        self.label = label; self.detail = detail; self.symbol = symbol; self.divider = divider; self.control = control
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: symbol == nil ? .center : .top, spacing: 12) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary).frame(width: 22).padding(.top, 1) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Theme.label).foregroundStyle(Theme.textPrimary)
                    if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.vertical, 11)
            if divider { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }
}

/// Campo de texto numa pílula de vidro.
struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var width: CGFloat = 260
    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain).font(Theme.body)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(width: width)
        .glassSurface(cornerRadius: Theme.radiusRow)
    }
}

/// Estado com bolinha colorida (ok, aviso, neutro).
struct StatusPill: View {
    enum Kind { case ok, warn, idle }
    let text: String
    let kind: Kind
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(kind == .ok ? Theme.ok : kind == .warn ? Theme.warning : Theme.textTertiary).frame(width: 7, height: 7)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassSurface(cornerRadius: 12)
    }
}

/// Página rolável de Ajustes: cabeçalho e seções.
struct SettingsPage<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(symbol: symbol, title: title, subtitle: subtitle)
                content()
            }
            .padding(Theme.gutter).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        // O fim da lista some antes da borda (não fica cortado embaixo dos botões).
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .toggleStyle(.switch).tint(Theme.accent)
    }
}
