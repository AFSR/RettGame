import Foundation
import CoreGraphics
import Observation

/// Calibrateur du regard — modèle **quadratique par axe**.
///
/// Pour chaque axe (x et y indépendamment) on apprend :
/// ```
/// ax = b₂ · (rx - μᵣ)² + b₁ · (rx - μᵣ) + μₐ
/// ```
/// où `μᵣ` est la moyenne des raw, `μₐ` la moyenne des actual.
///
/// **Pourquoi quadratique et pas affine ?** Le signal blendShape d'ARKit n'est
/// pas linéaire en l'angle de regard : la combinaison `(outR + inL) - (outL + inR)`
/// sature aux bords (les blendShapes individuels plafonnent à 1.0), donc le
/// raw écran sous-estime les positions extrêmes — un fit purement linéaire
/// compresse systématiquement le coin haut-gauche et le coin bas-droit vers
/// le centre. Le terme `b₂·(rx-μ)²` corrige cette courbure.
///
/// **Pourquoi par axe et pas 2D ?** L'ajout de termes croisés (`rx·ry`, etc.)
/// rend le système 6×6 mal conditionné dès qu'il y a la moindre corrélation
/// parasite entre rx et ry, et OLS collapse vers la moyenne. Le modèle par
/// axe est moins expressif (ne corrige pas la rotation) mais **structurellement
/// incapable de collapse**.
///
/// **Centrage** : on fit en coordonnées centrées (rxc = rx - μᵣ, axc = ax - μₐ),
/// ce qui élimine l'intercept et stabilise numériquement (les puissances 4
/// de rx en valeur absolue sont ~10¹⁴ ; en centré, ~10⁸).
///
/// **Bornes de sécurité** : la pente effective au centre `b₁` est clampée à
/// `[-20, -0.1] ∪ [0.1, 20]` pour éviter qu'un fit dégénéré ne renvoie
/// l'identité ou n'amplifie à l'infini.
///
/// **Rejet d'outliers** : un premier fit, calcul des résidus, suppression
/// des samples au-delà de `max(80 px, 3 × médiane)`, refit. Évite qu'un
/// tap parent raté empoisonne la calibration.
@Observable
final class GazeCalibrator {
    static let shared = GazeCalibrator()

    struct Sample: Codable, Equatable {
        let rx: Double; let ry: Double
        let ax: Double; let ay: Double
    }

    private var samples: [Sample] = []
    private let maxSamples: Int
    /// Format raw/actual inchangé depuis v3 → on garde la clé pour ne pas
    /// effacer les calibrations existantes des utilisateurs.
    private let persistenceKey = "afsr.eyegame.calibration.samples.v3"

    /// Paramètres ajustés par axe.
    private struct AxisFit {
        var meanR: Double = 0      // moyenne raw sur cet axe
        var meanA: Double = 0      // moyenne actual sur cet axe
        var b1: Double = 1         // pente effective au centre
        var b2: Double = 0         // courbure quadratique
    }
    private var xFit = AxisFit()
    private var yFit = AxisFit()

    /// Diagnostic / compat : pente effective au centre = `b₁`.
    var m00: CGFloat { CGFloat(xFit.b1) }
    var m11: CGFloat { CGFloat(yFit.b1) }
    /// Termes croisés non utilisés dans ce modèle (gardés pour compat API).
    var m01: CGFloat { 0 }
    var m10: CGFloat { 0 }
    var tx: CGFloat { CGFloat(xFit.meanA - xFit.b1 * xFit.meanR) }
    var ty: CGFloat { CGFloat(yFit.meanA - yFit.b1 * yFit.meanR) }

    private let minGain: Double = 0.1
    private let maxGain: Double = 20.0
    /// Minimum d'échantillons avant d'appliquer la transformation. 5 = peu
    /// au-dessus des 3 nécessaires pour un fit quadratique stable par axe.
    private let minSamplesToApply: Int = 5

    init(maxSamples: Int = 200) {
        self.maxSamples = maxSamples
        load()
        recompute()
    }

    // MARK: - Public API

    var samplesCount: Int { samples.count }

    func addSample(raw: CGPoint, actual: CGPoint) {
        samples.append(Sample(
            rx: Double(raw.x), ry: Double(raw.y),
            ax: Double(actual.x), ay: Double(actual.y)
        ))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        recompute()
        save()
    }

    func reset() {
        samples.removeAll()
        xFit = AxisFit()
        yFit = AxisFit()
        save()
    }

    func apply(_ raw: CGPoint) -> CGPoint {
        guard samples.count >= minSamplesToApply else { return raw }
        let rxc = Double(raw.x) - xFit.meanR
        let ryc = Double(raw.y) - yFit.meanR
        let predX = xFit.b2 * rxc * rxc + xFit.b1 * rxc + xFit.meanA
        let predY = yFit.b2 * ryc * ryc + yFit.b1 * ryc + yFit.meanA
        return CGPoint(x: predX, y: predY)
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data)
        else { return }
        samples = decoded
        if samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
    }

    // MARK: - Regression (per-axis quadratic OLS + outlier rejection)

    private func recompute() {
        guard samples.count >= minSamplesToApply else {
            xFit = AxisFit()
            yFit = AxisFit()
            return
        }

        let p1x = fitAxis(samples, raw: \.rx, actual: \.ax)
        let p1y = fitAxis(samples, raw: \.ry, actual: \.ay)
        xFit = p1x
        yFit = p1y

        // Rejet d'outliers : besoin d'au moins 9 samples pour garder ≥ 5 après
        // filtrage (minimum requis pour fitter à nouveau).
        guard samples.count >= 9 else { return }

        let residuals = samples.map { residual(of: $0) }
        let sorted = residuals.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(80.0, 3.0 * median)
        let inliers = zip(samples, residuals)
            .filter { $0.1 <= threshold }
            .map { $0.0 }

        if inliers.count >= minSamplesToApply {
            xFit = fitAxis(inliers, raw: \.rx, actual: \.ax)
            yFit = fitAxis(inliers, raw: \.ry, actual: \.ay)
        }
    }

    @inline(__always)
    private func residual(of s: Sample) -> Double {
        let rxc = s.rx - xFit.meanR
        let ryc = s.ry - yFit.meanR
        let predX = xFit.b2 * rxc * rxc + xFit.b1 * rxc + xFit.meanA
        let predY = yFit.b2 * ryc * ryc + yFit.b1 * ryc + yFit.meanA
        let dx = predX - s.ax
        let dy = predY - s.ay
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Fit quadratique sur un axe via OLS centré.
    ///
    /// Modèle : `axc = b₂·rxc² + b₁·rxc` (pas d'intercept, données centrées).
    /// Équations normales 2×2 fermées :
    /// ```
    /// [Σrxc⁴  Σrxc³] [b₂]   [Σrxc²·axc]
    /// [Σrxc³  Σrxc²] [b₁] = [Σrxc·axc ]
    /// ```
    private func fitAxis(_ samples: [Sample],
                         raw: KeyPath<Sample, Double>,
                         actual: KeyPath<Sample, Double>) -> AxisFit {
        let n = Double(samples.count)
        guard n >= Double(minSamplesToApply) else { return AxisFit() }

        var meanR = 0.0, meanA = 0.0
        for s in samples {
            meanR += s[keyPath: raw]
            meanA += s[keyPath: actual]
        }
        meanR /= n; meanA /= n

        var s2 = 0.0, s3 = 0.0, s4 = 0.0
        var sra = 0.0, s2ra = 0.0
        for s in samples {
            let rc = s[keyPath: raw] - meanR
            let ac = s[keyPath: actual] - meanA
            let rc2 = rc * rc
            s2 += rc2
            s3 += rc2 * rc
            s4 += rc2 * rc2
            sra += rc * ac
            s2ra += rc2 * ac
        }

        // Données dégénérées (tous les rx identiques) → identité.
        guard s2 > 1.0 else {
            return AxisFit(meanR: meanR, meanA: meanA, b1: 1, b2: 0)
        }

        // Système 2×2 : [[s4, s3], [s3, s2]] · [b2, b1]ᵀ = [s2ra, sra]ᵀ
        let det = s4 * s2 - s3 * s3
        var b1: Double
        var b2: Double
        if abs(det) < 1.0 {
            // Système quasi-singulier (rare) → on retombe sur le linéaire
            // pur, c'est-à-dire b₁ = covariance / variance, b₂ = 0.
            b2 = 0
            b1 = sra / s2
        } else {
            let invDet = 1.0 / det
            b2 = (s2 * s2ra - s3 * sra) * invDet
            b1 = (s4 * sra - s3 * s2ra) * invDet
        }

        // Clamp magnitude de b1 (la pente au centre) avec préservation du signe :
        // un gain trop petit collapse la sortie, un gain trop grand projette à
        // l'infini. b2 (courbure) n'est pas borné — il est intrinsèquement
        // petit grâce au centrage et la borne sur b1 suffit à garder l'output
        // dans un range raisonnable.
        let signedB1: Double = {
            let sign = b1 < 0 ? -1.0 : 1.0
            let mag = max(minGain, min(maxGain, abs(b1)))
            return sign * mag
        }()

        return AxisFit(meanR: meanR, meanA: meanA, b1: signedB1, b2: b2)
    }
}


