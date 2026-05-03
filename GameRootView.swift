import SwiftUI

/// Vue racine de RettGame : menu de lancement listant les expériences de jeu
/// disponibles (natif + portail web GazePlay). Lien vers les réglages dans la
/// barre d'outils.
struct GameRootView: View {
    @State private var showSettings = false
    @State private var showWebGazePlay = false

    private static let gazePlayURL = URL(string: "https://interaactionweb.afsr.fr/gazeplay/")!

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
                            title: "Jeu du Regard",
                            subtitle: "Tarte à la crème — pilotage par le regard via la caméra TrueDepth.",
                            iconSystemName: "eye.fill",
                            badge: "Natif"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        showWebGazePlay = true
                    } label: {
                        GameCard(
                            title: "GazePlay",
                            subtitle: "Bulles colorées et autres jeux web pilotables au regard, depuis le portail InterAACtion.",
                            iconSystemName: "play.rectangle.fill",
                            badge: "Web"
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
            .fullScreenCover(isPresented: $showWebGazePlay) {
                NavigationStack {
                    SafariView(url: Self.gazePlayURL)
                        .ignoresSafeArea()
                        .navigationTitle("GazePlay")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Fermer") { showWebGazePlay = false }
                            }
                        }
                }
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
    let badge: String

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
                HStack(spacing: 8) {
                    Text(title)
                        .font(AFSRFont.headline(20))
                        .foregroundStyle(.primary)
                    Text(badge)
                        .font(AFSRFont.caption(11))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.afsrPurpleAdaptive, in: Capsule())
                }
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
