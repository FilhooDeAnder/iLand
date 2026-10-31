import SwiftUI

/// Página "Atalhos": modo escuro, ícones da mesa, lixeira, bloquear, cor da tela e texto da tela.
struct ShortcutsPage: View {
    @ObservedObject var s: ShortcutsModel

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                tile("circle.lefthalf.filled", "Modo escuro", s.toggleDarkMode)
                tile("menubar.dock.rectangle", s.confirmingFinder ? "Reinicia o Finder. Confirmar?" : "Ícones da mesa", s.toggleDesktopIcons, tint: s.confirmingFinder ? .orange : .white)
                tile("trash", s.confirmingTrash ? "Confirmar?" : "Esvaziar lixeira", s.emptyTrash, tint: s.confirmingTrash ? .orange : .white)
                tile("lock", "Bloquear tela", s.lockScreen)
                tile("eyedropper", "Cor da tela", s.pickColor)
                tile("text.viewfinder", "Texto da tela", s.copyTextFromScreen)
            }
            Text(s.message.isEmpty ? "Cor e texto: selecione na tela e o resultado vai para a área de transferência." : s.message)
                .font(.system(size: 10)).foregroundColor(s.message.isEmpty ? secondary : .white).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.top, NotchLayout.ear).padding(.bottom, 22)
    }

    private func tile(_ icon: String, _ title: String, _ action: @escaping () -> Void, tint: Color = .white) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Página "Notas": um bloco de texto que salva sozinho.
struct NotesPage: View {
    @ObservedObject var notes: NotesModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.09))
            TextEditor(text: $notes.text)
                .font(.system(size: 12)).foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(6)
            if notes.text.isEmpty {
                Text("Escreva aqui. Salva sozinho.").font(.system(size: 12)).foregroundColor(secondary).padding(.leading, 11).padding(.top, 6).allowsHitTesting(false)
            }
        }
        .frame(height: 138)
        .padding(.horizontal, 18).padding(.top, NotchLayout.ear).padding(.bottom, 22)
    }
}
