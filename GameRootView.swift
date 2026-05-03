import SwiftUI

/// Vue racine de RettGame : navigation native vers le jeu, lien vers les réglages
/// dans la barre d'outils. Pas de tabs, pas de SwiftData, pas d'auth — l'app n'a
/// qu'une seule fonction : faire jouer l'enfant.
struct GameRootView: View {
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            EyeGameView()
                .navigationTitle("Jeu du Regard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel("Réglages")
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack { GameSettingsView() }
                }
        }
    }
}

#Preview {
    GameRootView()
}
