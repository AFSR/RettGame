import SwiftUI
import UIKit

// MARK: - Charte graphique AFSR (v1.3)
//
// Source : dépôt AFSR/charte_graphique (docs/CHARTE.md, dist/tokens.resolved.json).
// Les valeurs de marque sont celles de la charte, sans variante inventée. La charte ne
// définit que le thème clair : les variantes sombres (`afsrAdaptive`) en sont dérivées
// (teintes plus claires de la même famille) pour garder un contraste suffisant.
//
// Règles retenues : une couleur dominante par écran (magenta) ; le violet porte le texte ;
// lime et jaune restent des accents à doser ; texte jamais sous 12 pt ; boutons au rayon 20.

// MARK: - Couleurs de marque

extension Color {
    /// magenta-100 · primaire (boutons, liens)
    static let afsrPrimary       = Color(hex: "#9e1981")
    /// magenta-110 · survol / appui
    static let afsrPrimaryHover  = Color(hex: "#84156c")
    /// magenta-90 · bordure du bouton principal
    static let afsrPrimaryBorder = Color(hex: "#ae3f96")
    /// magenta-50 · aplat doux
    static let afsrPrimarySoft   = Color(hex: "#ecd1e6")
    /// purple-100 · tertiaire (aplats, ombres)
    static let afsrTertiary      = Color(hex: "#68257c")
    /// violet-100 · texte et structure
    static let afsrViolet        = Color(hex: "#3f266c")
    /// violet-120 / violet-140 · fonds sombres (écran de calibration)
    static let afsrVioletNight   = Color(hex: "#2a1948")
    static let afsrVioletDeep    = Color(hex: "#150d24")
    /// lime-100, lime-90 · accent décoratif
    static let afsrLime          = Color(hex: "#afcb27")
    static let afsrLimeBright    = Color(hex: "#bcd44b")
    /// green-100
    static let afsrGreen         = Color(hex: "#54b366")
    /// yellow-100, yellow-90
    static let afsrYellow        = Color(hex: "#dedc00")
    static let afsrYellowBright  = Color(hex: "#e3e22b")

    /// Couleur qui change avec le mode clair / sombre.
    static func afsrAdaptive(light: String, dark: String) -> Color {
        let lightColor = UIColor(Color(hex: light))
        let darkColor = UIColor(Color(hex: dark))
        return Color(UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }
}

// MARK: - Rôles (adaptés au mode sombre)

extension Color {
    /// Teinte magenta pour texte, icônes et liens : magenta-100 en clair, magenta-70 en sombre
    /// (magenta-100 sur fond noir n'atteint pas le contraste utile).
    static let afsrPrimaryAdaptive = afsrAdaptive(light: "#9e1981", dark: "#ce8cc0")
    /// `text` : violet-100.
    static let afsrText     = afsrAdaptive(light: "#3f266c", dark: "#ffffff")
    /// `text-soft` : violet-90 (contraste 7,5 sur blanc).
    static let afsrTextSoft = afsrAdaptive(light: "#5f4a84", dark: "#bfb7ce")
    /// `border` : magenta-30. Décorative seulement (contraste ~1,2) : jamais seule pour délimiter.
    static let afsrBorder   = afsrAdaptive(light: "#f5e8f2", dark: "#ffffff22")
    /// Erreur : `#b00020` (texte AA) ; en sombre, le rouge vif du site pour garder le contraste.
    static let afsrEmergency = afsrAdaptive(light: "#b00020", dark: "#e84143")
    /// Succès : forest-100 ; en sombre green-100.
    static let afsrSuccess   = afsrAdaptive(light: "#216442", dark: "#54b366")
    /// Avertissement : `#7a5b00` ; en sombre yellow-100.
    static let afsrWarning   = afsrAdaptive(light: "#7a5b00", dark: "#dedc00")

    /// `surface` : blanc ; en sombre, la surface groupée du système.
    static let afsrSurface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor.secondarySystemGroupedBackground : UIColor.white
    })
    /// Fond de page : magenta-10 (`#fbf6fa`) ; en sombre, le fond groupé du système.
    static let afsrBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.systemGroupedBackground
            : UIColor(red: 251 / 255, green: 246 / 255, blue: 250 / 255, alpha: 1)
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

// MARK: - Raccourcis ShapeStyle (`.foregroundStyle(.afsrText)`)

extension ShapeStyle where Self == Color {
    static var afsrPrimary: Color         { .afsrPrimary }
    static var afsrPrimaryHover: Color    { .afsrPrimaryHover }
    static var afsrPrimarySoft: Color     { .afsrPrimarySoft }
    static var afsrPrimaryAdaptive: Color { .afsrPrimaryAdaptive }
    static var afsrViolet: Color          { .afsrViolet }
    static var afsrText: Color            { .afsrText }
    static var afsrTextSoft: Color        { .afsrTextSoft }
    static var afsrBackground: Color      { .afsrBackground }
    static var afsrSurface: Color         { .afsrSurface }
    static var afsrBorder: Color          { .afsrBorder }
    static var afsrEmergency: Color       { .afsrEmergency }
    static var afsrSuccess: Color         { .afsrSuccess }
    static var afsrWarning: Color         { .afsrWarning }
    static var afsrLime: Color            { .afsrLime }
    static var afsrYellow: Color          { .afsrYellow }
}

// MARK: - Typographie
//
// Titres : Unbounded. Texte : Montserrat (polices de la charte, licence SIL OFL, voir
// Resources/Fonts). Si une police manque, SwiftUI retombe sur la police système.
// Tailles fixes, comme avant : la mise en page des jeux ne dépend pas de Dynamic Type.

enum AFSRFont {
    /// Grands titres (écran de fin, titre de page).
    static func title(_ size: CGFloat = 28) -> Font {
        .custom("Unbounded-Bold", fixedSize: size)
    }

    /// Titres de section et de carte.
    static func headline(_ size: CGFloat = 18) -> Font {
        .custom("Unbounded-SemiBold", fixedSize: size)
    }

    /// Texte courant.
    static func body(_ size: CGFloat = 17) -> Font {
        .custom("Montserrat-Regular", fixedSize: size)
    }

    /// Légendes, aides, étiquettes. Jamais sous 12 pt (charte).
    static func caption(_ size: CGFloat = 13) -> Font {
        .custom("Montserrat-Medium", fixedSize: size)
    }

    /// Libellés de boutons.
    static func button(_ size: CGFloat = 17) -> Font {
        .custom("Montserrat-SemiBold", fixedSize: size)
    }

    /// Chiffres des pastilles (score, minuteur), à chasse constante.
    static func number(_ size: CGFloat = 17) -> Font {
        .custom("Montserrat-Bold", fixedSize: size).monospacedDigit()
    }
}

// MARK: - Formes et espacements (rayons de la charte)

enum AFSRTokens {
    /// radius.lg : boutons et cartes.
    static let cornerRadius: CGFloat = 20
    /// radius.xl
    static let cornerRadiusLarge: CGFloat = 36
    /// radius.md
    static let cornerRadiusSmall: CGFloat = 12
    static let spacing: CGFloat = 16
    static let spacingLarge: CGFloat = 24
    static let spacingSmall: CGFloat = 8
    static let minTapTarget: CGFloat = 60
}

// MARK: - Carte

/// Carte de la charte : surface blanche, filet magenta-30, ombre violette douce (shadow.lg
/// approximée : SwiftUI ne gère qu'une ombre).
struct AFSRCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AFSRTokens.spacing)
            .background(Color.afsrSurface)
            .clipShape(RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AFSRTokens.cornerRadius, style: .continuous)
                    .stroke(Color.afsrBorder, lineWidth: 1)
            )
            .shadow(color: Color.afsrViolet.opacity(0.08), radius: 10, x: 0, y: 6)
    }
}

extension View {
    func afsrCard() -> some View { modifier(AFSRCardStyle()) }
}

// MARK: - Apparence UIKit (barre de navigation, contrôles segmentés)

enum AFSRAppearance {
    /// À appeler une fois au lancement. Les contrôles SwiftUI s'appuient sur UIKit pour ces deux
    /// éléments : le style doit donc passer par les proxies d'apparence.
    static func configure() {
        let text = UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(Color(hex: "#3f266c")) }
        let primary = UIColor(Color(hex: "#9e1981"))

        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        style(standard, text: text)

        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        style(scrollEdge, text: text)

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = standard
        bar.compactAppearance = standard
        bar.scrollEdgeAppearance = scrollEdge

        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = primary
        segmented.setTitleTextAttributes(
            [.foregroundColor: UIColor.white, .font: font("Montserrat-SemiBold", 14, .semibold)],
            for: .selected)
        segmented.setTitleTextAttributes(
            [.foregroundColor: text, .font: font("Montserrat-Medium", 14, .medium)],
            for: .normal)
    }

    private static func style(_ appearance: UINavigationBarAppearance, text: UIColor) {
        appearance.titleTextAttributes = [
            .foregroundColor: text,
            .font: font("Unbounded-SemiBold", 16, .semibold),
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: text,
            .font: font("Unbounded-Bold", 30, .bold),
        ]
    }

    private static func font(_ name: String, _ size: CGFloat, _ fallback: UIFont.Weight) -> UIFont {
        UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: fallback)
    }
}
