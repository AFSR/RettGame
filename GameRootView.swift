import SwiftUI

/// Vue racine de RettGame : menu de lancement listant les expériences de jeu
/// natives (déclinaisons des jeux GazePlay). Lien vers les réglages dans la
/// barre d'outils. Graphisme conforme à la charte AFSR (voir AFSRTheme).
struct GameRootView: View {
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Header()
                        .padding(.top, 16)

                    NavigationLink {
                        EyeGameView()
                    } label: {
                        GameCard(
                            title: "Tartes à la crème",
                            subtitle: "Vise les personnages avec ton regard pour leur envoyer une tarte 🥧.",
                            iconSystemName: "fork.knife.circle.fill"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        BubblesGameView()
                    } label: {
                        GameCard(
                            title: "Bulles colorées",
                            subtitle: "Fais éclater les bulles qui montent en les regardant 🫧.",
                            iconSystemName: "circle.hexagongrid.fill"
                        )
                    }
                    .buttonStyle(.plain)
                }
                // Largeur de lecture limitée : sur iPad les cartes ne s'étirent pas sur tout l'écran.
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color.afsrBackground.ignoresSafeArea())
            .navigationTitle("RettGame")
            .navigationBarTitleDisplayMode(.large)
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

private struct Header: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("AFSRLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260)
                .accessibilityLabel("Association Française du Syndrome de Rett")
            Text("Choisissez une activité")
                .font(AFSRFont.headline(17))
                .foregroundStyle(.afsrText)
        }
    }
}

private struct GameCard: View {
    let title: String
    let subtitle: String
    let iconSystemName: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: AFSRTokens.cornerRadiusSmall + 6, style: .continuous)
                    .fill(Color.afsrPrimarySoft)
                    .frame(width: 64, height: 64)
                Image(systemName: iconSystemName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.afsrPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AFSRFont.headline(17))
                    .foregroundStyle(.afsrText)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(AFSRFont.body(15))
                    .foregroundStyle(.afsrTextSoft)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.afsrPrimaryAdaptive)
        }
        .afsrCard()
    }
}

#Preview {
    GameRootView()
}
