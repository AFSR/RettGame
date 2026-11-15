import Foundation

/// Clés UserDefaults et valeurs par défaut pour les réglages du jeu regard.
/// Partagées entre `EyeGameViewModel` et la section Réglages dédiée.
enum EyeGameSettings {
    static let smoothingEnabledKey = "afsr.eyegame.smoothing.enabled"
    static let smoothingStrengthKey = "afsr.eyegame.smoothing.strength"
    /// Affiche des mesures techniques pendant la calibration (désactivé par défaut).
    static let diagnosticKey = "afsr.eyegame.diagnostic"

    static let defaultSmoothingStrength: Double = 0.4
}
