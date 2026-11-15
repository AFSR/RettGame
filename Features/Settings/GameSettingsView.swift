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
                    Label("Le jeu utilise la caméra frontale pour suivre le regard de votre enfant.", systemImage: "eye")
                    Label("Aucune image n'est enregistrée ni transmise.", systemImage: "lock.shield.fill")
                    Label("La calibration est conservée localement entre les parties.", systemImage: "scope")
                }
                .font(AFSRFont.caption())
                .foregroundStyle(.afsrTextSoft)
            } header: {
                Text("Confidentialité")
            }

            Section("À propos") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion).foregroundStyle(.afsrTextSoft).monospacedDigit()
                }
                Link(destination: AFSRLinks.website) {
                    Label("Site officiel AFSR", systemImage: "safari")
                }
                Link(destination: AFSRLinks.donation) {
                    Label("Soutenir l'AFSR", systemImage: "heart.fill")
                        .foregroundStyle(.afsrPrimaryAdaptive)
                }
            }

            Section {
                Text("RettGame est un compagnon de l'application principale RettApp, dédié exclusivement au jeu de communication par le regard. Conçu par et pour les familles concernées par le syndrome de Rett.")
                    .font(AFSRFont.caption())
                    .foregroundStyle(.afsrTextSoft)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.afsrBackground)
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
