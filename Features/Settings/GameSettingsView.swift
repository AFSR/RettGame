import SwiftUI

/// Réglages de RettGame : tuning du filtre, reset calibration, infos de l'app.
struct GameSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            EyeGameSettingsSection()

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Le jeu utilise la caméra TrueDepth (Face ID) pour suivre le regard de votre enfant.", systemImage: "faceid")
                    Label("Aucune image n'est enregistrée ni transmise.", systemImage: "lock.shield.fill")
                    Label("La calibration est conservée localement entre les parties.", systemImage: "scope")
                }
                .font(AFSRFont.caption())
                .foregroundStyle(.secondary)
            } header: {
                Text("Confidentialité")
            }

            Section("À propos") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion).foregroundStyle(.secondary).monospacedDigit()
                }
                Link(destination: URL(string: "https://afsr.fr")!) {
                    Label("Site officiel AFSR", systemImage: "safari")
                }
                Link(destination: URL(string: "https://afsr.fr/nous-soutenir/faire-un-don")!) {
                    Label("Soutenir l'AFSR", systemImage: "heart.fill")
                        .foregroundStyle(.afsrEmergency)
                }
            }

            Section {
                Text("RettGame est un compagnon de l'application principale RettApp, dédié exclusivement au jeu de communication par le regard. Conçu par et pour les familles concernées par le syndrome de Rett.")
                    .font(AFSRFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Réglages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fermer") { dismiss() }
            }
        }
    }
}

#Preview {
    NavigationStack { GameSettingsView() }
}
