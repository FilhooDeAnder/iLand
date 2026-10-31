import SwiftUI

/// Página "Captura": captura de área, prévia, copiar e enviar (botão); a engrenagem abre os Ajustes de captura.
struct CapturePage: View {
    @ObservedObject var cap: CaptureModel
    @ObservedObject var cfg: S3Settings

    init(cap: CaptureModel) { self.cap = cap; self.cfg = cap.settings }

    var body: some View {
        main
            .padding(.horizontal, 18).padding(.top, NotchLayout.ear).padding(.bottom, 22)
            .onChange(of: cap.editingConfig) { open in if open { SettingsWindow.shared.show(.capture); cap.editingConfig = false } }
    }

    private var main: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09))
                    if let img = cap.image {
                        Image(nsImage: img).resizable().scaledToFit().padding(4).onTapGesture { CapturePreviewController.shared.show(model: cap) }.help("Abrir prévia")
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.viewfinder").font(.system(size: 20))
                            Text("Nenhuma captura").font(.system(size: 10))
                        }.foregroundColor(secondary)
                    }
                }
                .frame(width: 190, height: 92)
                VStack(spacing: 5) {
                    Button(cap.capturing ? "Capturando…" : "Capturar área", action: cap.capture).buttonStyle(CapsuleStyle(fill: true)).disabled(cap.capturing || cap.uploading)
                    Button("Copiar imagem", action: cap.copyImage).buttonStyle(CapsuleStyle(fill: true)).disabled(cap.image == nil)
                    Button(cap.uploading ? "Enviando…" : "Enviar ao S3", action: cap.upload).buttonStyle(CapsuleStyle(tint: .orange, fill: true))
                        .disabled(cap.image == nil || cap.uploading || cap.capturing)
                }
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 6) {
                Text(cap.message.isEmpty ? (cfg.ready ? "S3: \(cfg.config.bucket) (\(cfg.config.region))" : "S3 não configurado") : cap.message)
                    .font(.system(size: 10)).foregroundColor(cap.message.isEmpty ? secondary : .white).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { SettingsWindow.shared.show(.capture) } label: { Image(systemName: "gearshape").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(secondary).help("Ajustes de captura e envio")
            }
        }
    }
}
