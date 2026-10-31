import SwiftUI

/// Ajustes do envio (aba Captura): Amazon ou serviço compatível, chaves no Keychain, link e teste de conexão.
struct UploadSettings: View {
    @ObservedObject var cfg: S3Settings = .shared
    @State private var testing = false
    @State private var testResult: (String, StatusPill.Kind)?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            GlassSection("Envio de imagens e link", footer: cfg.ready || !cfg.config.enabled ? nil : "Falta preencher bucket, região e as chaves. As chaves ficam no Keychain do Mac.") {
                SettingRow("Envio", detail: "O botão de nuvem da miniatura e do editor.", divider: cfg.config.enabled) {
                    Picker("", selection: $cfg.config.enabled) { Text("Ligado").tag(true); Text("Desligado").tag(false) }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                }
                if cfg.config.enabled {
                    SettingRow("Serviço") {
                        Picker("", selection: Binding(get: { cfg.config.custom }, set: { cfg.config.endpoint = $0 ? "https://" : ""; if $0 { cfg.config.region = "auto" } else { cfg.config.region = "us-east-1" } })) {
                            Text("Amazon (AWS)").tag(false); Text("Outro (R2, MinIO, Backblaze…)").tag(true)
                        }.labelsHidden().frame(width: 250)
                    }
                    SettingRow("Bucket") { GlassField(placeholder: "nome do bucket", text: $cfg.config.bucket, width: 250) }
                    SettingRow(cfg.config.custom ? "Região (R2: auto)" : "Região") { GlassField(placeholder: cfg.config.custom ? "auto" : "us-east-1", text: $cfg.config.region, width: 250) }
                    if cfg.config.custom {
                        SettingRow("Endereço (endpoint)", detail: "https://… (http só em localhost).") { GlassField(placeholder: "https://conta.r2.cloudflarestorage.com", text: $cfg.config.endpoint, width: 250) }
                    }
                    SettingRow("Pasta no bucket", detail: "Opcional.") { GlassField(placeholder: "prints/", text: $cfg.config.prefix, width: 250) }
                    SettingRow(cfg.hasCredentials ? "Chave de acesso (salva)" : "Chave de acesso") { GlassField(placeholder: cfg.hasCredentials ? "digite para trocar" : "Access key", text: $cfg.accessKey, width: 250) }
                    SettingRow("Chave secreta") { GlassField(placeholder: cfg.hasCredentials ? "digite para trocar" : "Secret key", text: $cfg.secret, secure: true, width: 250) }
                    SettingRow("Conexão", detail: testResult?.0, divider: false) {
                        HStack(spacing: 8) {
                            if cfg.hasCredentials { Button("Apagar chaves") { cfg.removeCredentials(); testResult = nil }.glassButton() }
                            Button(testing ? "Testando…" : "Testar conexão") { test() }.glassButton().disabled(testing)
                            Button(saved ? "Salvo" : "Salvar") { cfg.save(); saved = true; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false } }.glassButton(prominent: true)
                        }
                    }
                }
            }
            if cfg.config.enabled {
                GlassSection("Link", footer: cfg.config.sharing == "presigned" ? "Link assinado vale até 7 dias. Depois ele para de abrir, mas o arquivo continua no bucket." : nil) {
                    SettingRow("Depois do envio", divider: cfg.config.sharing != "none") {
                        Picker("", selection: $cfg.config.sharing) { Text("Não gerar link").tag("none"); Text("Link assinado (expira)").tag("presigned"); Text("Link público do bucket").tag("public") }
                            .labelsHidden().frame(width: 220)
                    }
                    if cfg.config.sharing == "presigned" {
                        SettingRow("Validade do link", divider: false) {
                            Stepper(value: $cfg.config.expiresHours, in: 1...168) { Text("\(cfg.config.expiresHours) h").monospacedDigit() }.frame(width: 120)
                        }
                    }
                    if cfg.config.sharing == "public" {
                        SettingRow("Endereço público", detail: "Só funciona se o bucket for público. Vazio = endereço do próprio bucket.", divider: false) {
                            GlassField(placeholder: "https://cdn.exemplo.com", text: $cfg.config.publicBase, width: 250)
                        }
                    }
                }
            }
        }
        .onChange(of: cfg.config) { _ in saved = false; testResult = nil; cfg.save(persistCredentials: false) }
    }

    private func test() {
        let typedKey = cfg.accessKey.trimmingCharacters(in: .whitespaces), typedSecret = cfg.secret.trimmingCharacters(in: .whitespaces)
        let creds = (!typedKey.isEmpty && !typedSecret.isEmpty) ? S3Credentials(accessKey: typedKey, secret: typedSecret) : cfg.credentials()
        guard let creds else { testResult = ("Digite as chaves primeiro.", .warn); return }
        testing = true; testResult = nil
        S3Client.testConnection(config: cfg.config, creds: creds) { result in
            DispatchQueue.main.async {
                testing = false
                switch result {
                case .success: testResult = ("Conexão ok.", .ok)
                case .failure(let e): testResult = (e.localizedDescription, .warn)
                }
            }
        }
    }
}
