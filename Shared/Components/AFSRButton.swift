import SwiftUI

// MARK: - Primary button

struct AFSRPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var color: Color = .afsrPurpleAdaptive
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon { Image(systemName: icon) }
                Text(title)
                    .font(AFSRFont.headline(18))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: AFSRTokens.minTapTarget)
            .foregroundStyle(.white)
            .background(color, in: RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Secondary / outline button

struct AFSRSecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon { Image(systemName: icon) }
                Text(title)
                    .font(AFSRFont.headline(17))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: AFSRTokens.minTapTarget)
            .foregroundStyle(.afsrPurpleAdaptive)
            .overlay(
                RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous)
                    .stroke(Color.afsrPurpleAdaptive, lineWidth: 2)
            )
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
                    .font(AFSRFont.headline(22))
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
}
