import SwiftUI

/// Section "Jeu du Regard" dans les Réglages :
/// - toggle pour activer/désactiver le lissage Kalman
/// - slider pour ajuster la force du lissage
/// - bouton pour réinitialiser la calibration persistée
struct EyeGameSettingsSection: View {
    @AppStorage(EyeGameSettings.smoothingEnabledKey) private var smoothingEnabled: Bool = true
    @AppStorage(EyeGameSettings.smoothingStrengthKey) private var smoothingStrength: Double = EyeGameSettings.defaultSmoothingStrength

    @AppStorage(EyeGameSettings.diagnosticKey) private var diagnosticEnabled: Bool = false

    @State private var showResetConfirm = false

    var body: some View {
        Section {
            Toggle(isOn: $smoothingEnabled) {
                Label("Lissage du regard (Kalman)", systemImage: "waveform")
            }

            if smoothingEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Force du lissage")
                        Spacer()
                        Text("\(Int(smoothingStrength * 100)) %")
                            .foregroundStyle(.afsrTextSoft)
                            .monospacedDigit()
                    }
                    Slider(value: $smoothingStrength, in: 0...1)
                    HStack {
                        Text("Réactif").font(AFSRFont.caption()).foregroundStyle(.afsrTextSoft)
                        Spacer()
                        Text("Lisse").font(AFSRFont.caption()).foregroundStyle(.afsrTextSoft)
                    }
                }
                .padding(.vertical, 4)
            }

            Toggle(isOn: $diagnosticEnabled) {
                Label("Mode diagnostic", systemImage: "waveform.path.ecg")
            }

            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Réinitialiser la calibration", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Jeu du Regard")
        } footer: {
            Text("La calibration est conservée entre les parties. Si le point du regard devient imprécis, relancez quelques taps ou réinitialisez la calibration. Le mode diagnostic affiche des mesures techniques pendant la calibration.")
        }
        .confirmationDialog(
            "Réinitialiser la calibration du regard ?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Réinitialiser", role: .destructive) {
                GazeCalibrator.shared.reset()
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Tous les points de calibration enregistrés seront supprimés.")
        }
    }
}

#Preview {
    Form {
        EyeGameSettingsSection()
    }
}
