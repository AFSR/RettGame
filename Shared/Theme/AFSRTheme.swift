import SwiftUI
import UIKit

// MARK: - Colors

extension Color {
    static let afsrPurple      = Color(hex: "#6B3FA0")
    static let afsrPurpleLight = Color(hex: "#9B6FC8")
    static let afsrPurpleDark  = Color(hex: "#4A2070")
    static let afsrWhite       = Color.white
    static let afsrAccent      = Color(hex: "#E8D5F7")
    static let afsrEmergency   = Color(hex: "#E53935")
    static let afsrSuccess     = Color(hex: "#43A047")
    static let afsrWarning     = Color(hex: "#FB8C00")

    /// Fond principal des écrans : lavande très pâle en mode clair (identité AFSR),
    /// fond sombre système en mode sombre (cohérent avec Forms/Lists système).
    static let afsrBackground = Color(UIColor { trait in
        switch trait.userInterfaceStyle {
        case .dark:
            return UIColor.systemGroupedBackground
        default:
            return UIColor(red: 0.973, green: 0.961, blue: 0.988, alpha: 1) // #F8F5FC
        }
    })

    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&rgb)
        let r, g, b, a: Double
        switch trimmed.count {
        case 6:
            r = Double((rgb >> 16) & 0xFF) / 255.0
            g = Double((rgb >> 8) & 0xFF) / 255.0
            b = Double(rgb & 0xFF) / 255.0
            a = 1.0
        case 8:
            r = Double((rgb >> 24) & 0xFF) / 255.0
            g = Double((rgb >> 16) & 0xFF) / 255.0
            b = Double((rgb >> 8) & 0xFF) / 255.0
            a = Double(rgb & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Adaptive colors (automatically adjust to dark/light mode)

extension Color {
    /// Violet AFSR adaptatif : foncé en mode clair (bon contraste sur blanc),
    /// clair en mode sombre (bon contraste sur noir). Utilisée pour les
    /// éléments d'accentuation comme la teinte des onglets (`.tint`).
    static let afsrPurpleAdaptive = Color(UIColor { trait in
        switch trait.userInterfaceStyle {
        case .dark:
            return UIColor(Color.afsrPurpleLight)
        default:
            return UIColor(Color.afsrPurple)
        }
    })
}

// MARK: - ShapeStyle shortcuts (for `.foregroundStyle(.afsrPurple)` syntax)

extension ShapeStyle where Self == Color {
    static var afsrPurple: Color         { .afsrPurple }
    static var afsrPurpleLight: Color    { .afsrPurpleLight }
    static var afsrPurpleDark: Color     { .afsrPurpleDark }
    static var afsrPurpleAdaptive: Color { .afsrPurpleAdaptive }
    static var afsrBackground: Color     { .afsrBackground }
    static var afsrAccent: Color         { .afsrAccent }
    static var afsrEmergency: Color      { .afsrEmergency }
    static var afsrSuccess: Color        { .afsrSuccess }
    static var afsrWarning: Color        { .afsrWarning }
}

// MARK: - Typography

enum AFSRFont {
    static func title(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static func headline(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func body(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    static func caption(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    static func timer(_ size: CGFloat = 72) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }
}

// MARK: - Layout tokens

enum AFSRTokens {
    static let cornerRadius: CGFloat = 20
    static let cornerRadiusLarge: CGFloat = 24
    static let cornerRadiusSmall: CGFloat = 12
    static let shadowRadius: CGFloat = 8
    static let shadowOpacity: Double = 0.12
    static let spacing: CGFloat = 16
    static let spacingLarge: CGFloat = 24
    static let spacingSmall: CGFloat = 8
    static let minTapTarget: CGFloat = 60
}

// MARK: - View modifiers

struct AFSRCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AFSRTokens.spacing)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous))
            .shadow(
                color: .black.opacity(AFSRTokens.shadowOpacity),
                radius: AFSRTokens.shadowRadius,
                x: 0, y: 2
            )
    }
}

extension View {
    func afsrCard() -> some View { modifier(AFSRCardStyle()) }
}
