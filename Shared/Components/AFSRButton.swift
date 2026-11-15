import SwiftUI

// MARK: - Style de bouton plein (charte AFSR)
//
// Bouton principal : fond magenta-100, bordure magenta-90, texte blanc, rayon 20, appui en
// magenta-110, ombre `md`. Le fond plein reste le même en mode sombre : blanc sur magenta-100
// atteint un contraste de 7,2.

struct AFSRFilledButtonStyle: ButtonStyle {
    let fill: Color
    let pressedFill: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: AFSRTokens.minTapTarget)
            .background(
                configuration.isPressed ? pressedFill : fill,
                in: RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .shadow(color: Color.afsrTertiary.opacity(0.20), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Primary button

struct AFSRPrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon { Image(systemName: icon) }
                Text(title)
                    .font(AFSRFont.button(18))
            }
        }
        .buttonStyle(AFSRFilledButtonStyle(
            fill: .afsrPrimary,
            pressedFill: .afsrPrimaryHover,
            border: .afsrPrimaryBorder
        ))
    }
}

// MARK: - Secondary / outline button
//
// Bouton secondaire : fond blanc, bordure magenta-30, texte magenta.

struct AFSRSecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon { Image(systemName: icon) }
                Text(title)
                    .font(AFSRFont.button(17))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: AFSRTokens.minTapTarget)
            .foregroundStyle(.afsrPrimaryAdaptive)
            .background(
                Color.afsrSurface,
                in: RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous)
                    .stroke(Color.afsrBorder, lineWidth: 1.5)
            )
            .shadow(color: Color.afsrTertiary.opacity(0.20), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Emergency giant button

struct AFSREmergencyButton: View {
    let title: String
    var icon: String? = "bolt.heart.fill"
    var color: Color = .afsrEmergency
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 44, weight: .bold))
                }
                Text(title)
                    .font(AFSRFont.button(22))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(color, in: RoundedRectangle(cornerRadius: AFSRTokens.cornerRadiusLarge, style: .continuous))
            .shadow(color: color.opacity(0.4), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    VStack(spacing: 16) {
        AFSREmergencyButton(title: "🚨 Démarrer une crise") {}
        AFSRPrimaryButton(title: "Enregistrer", icon: "checkmark") {}
        AFSRSecondaryButton(title: "Annuler") {}
    }
    .padding()
    .background(Color.afsrBackground)
}
