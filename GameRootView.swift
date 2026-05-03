import SwiftUI

/// Vue racine de RettGame : menu de lancement listant les expériences de jeu
/// natives (déclinaisons des jeux GazePlay). Lien vers les réglages dans la
/// barre d'outils.
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
        VStack(spacing: 8) {
            Image("RettLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 100)
            Text("Choisissez une activité")
                .font(AFSRFont.headline())
                .foregroundStyle(.secondary)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.afsrPurple.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: iconSystemName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.afsrPurpleAdaptive)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AFSRFont.headline(20))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(AFSRFont.body(15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous)
                .stroke(Color.afsrPurple.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}

#Preview {
    GameRootView()
}
