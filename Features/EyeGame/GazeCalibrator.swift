import Foundation
import CoreGraphics
import Observation

/// Calibrateur du regard — modèle **affine 2D** complet.
///
/// On apprend une transformation à 6 paramètres :
/// ```
/// ax = m00 · rx + m01 · ry + tx
/// ay = m10 · rx + m11 · ry + ty
/// ```
/// Comparé à un fit 1D par axe (`ax = sx · rx + ox`), ce modèle peut absorber :
/// - une rotation entre le repère blendShape et le repère écran (utile en
///   landscape ou si la tête est inclinée),
/// - un skew / couplage croisé entre horizontal et vertical (typique du signal
///   blendShape oculaire qui n'est pas parfaitement orthogonal),
/// - l'inversion d'axes, l'échelle indépendante par axe, l'offset.
///
/// La résolution est en moindres carrés (équations normales 3×3, fermées).
/// Après le premier ajustement on calcule les résidus de chaque échantillon :
/// les outliers (taps parents loin du regard réel de l'enfant) sont supprimés
/// au-delà de `max(80 px, 3 × médiane)` puis on refit. Cette étape évite qu'un
/// seul tap raté empoisonne toute la calibration.
@Observable
final class GazeCalibrator {
    static let shared = GazeCalibrator()

    struct Sample: Codable, Equatable {
        let rx: Double; let ry: Double
        let ax: Double; let ay: Double
    }

    private var samples: [Sample] = []
    private let maxSamples: Int
    /// Clé de persistance — le format raw/actual est inchangé depuis v3, donc
    /// on garde la même clé : les utilisateurs ne perdent pas leur calibration
    /// au passage du modèle 1D au modèle 2D.
    private let persistenceKey = "afsr.eyegame.calibration.samples.v3"

    /// Paramètres du modèle affine. Matrice 2×2 + translation.
    private(set) var m00: CGFloat = 1
    private(set) var m01: CGFloat = 0
    private(set) var tx:  CGFloat = 0
    private(set) var m10: CGFloat = 0
    private(set) var m11: CGFloat = 1
    private(set) var ty:  CGFloat = 0

    init(maxSamples: Int = 200) {
        self.maxSamples = maxSamples
        load()
        recompute()
    }

    // MARK: - Public API

    var samplesCount: Int { samples.count }

    /// Ajoute un échantillon, recalcule la transformation et persiste.
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
        m00 = 1; m01 = 0; tx = 0
        m10 = 0; m11 = 1; ty = 0
        save()
    }

    /// Applique la transformation affine au point brut. Si trop peu de
    /// samples pour fitter de façon stable, retourne `raw`.
    func apply(_ raw: CGPoint) -> CGPoint {
        guard samples.count >= 3 else { return raw }
        return CGPoint(
            x: m00 * raw.x + m01 * raw.y + tx,
            y: m10 * raw.x + m11 * raw.y + ty
        )
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

    // MARK: - Regression (least squares + outlier rejection)

    private func recompute() {
        guard samples.count >= 3 else {
            m00 = 1; m01 = 0; tx = 0
            m10 = 0; m11 = 1; ty = 0
            return
        }

        // Première passe : OLS sur tous les samples.
        guard let p1 = fitAffine(samples) else { return }
        apply(params: p1)

        // Deuxième passe : on rejette les outliers si on a assez de samples
        // pour se le permettre (au moins 9 → minimum requis par la calibration
        // guidée, garde 3+ après rejet).
        guard samples.count >= 9 else { return }

        let residuals = samples.map { residual(of: $0) }
        let sorted = residuals.sorted()
        let median = sorted[sorted.count / 2]
        // Garde un plancher absolu : avec peu de bruit la médiane peut être
        // toute petite, on ne veut pas exclure des points légitimes.
        let threshold = max(80.0, 3.0 * median)
        let inliers = zip(samples, residuals)
            .filter { $0.1 <= threshold }
            .map { $0.0 }

        // Si on a coupé trop de samples ou la matrice devient mal posée, on
        // garde le premier fit.
        if inliers.count >= 3, let p2 = fitAffine(inliers) {
            apply(params: p2)
        }
    }

    private func apply(params p: AffineParams) {
        m00 = CGFloat(p.m00); m01 = CGFloat(p.m01); tx = CGFloat(p.tx)
        m10 = CGFloat(p.m10); m11 = CGFloat(p.m11); ty = CGFloat(p.ty)
    }

    @inline(__always)
    private func residual(of s: Sample) -> Double {
        let predX = Double(m00) * s.rx + Double(m01) * s.ry + Double(tx)
        let predY = Double(m10) * s.rx + Double(m11) * s.ry + Double(ty)
        let dx = predX - s.ax
        let dy = predY - s.ay
        return (dx * dx + dy * dy).squareRoot()
    }

    private struct AffineParams {
        let m00: Double; let m01: Double; let tx: Double
        let m10: Double; let m11: Double; let ty: Double
    }

    /// Moindres carrés fermés via équations normales :
    /// X ∈ ℝ^{N×3} (lignes `[rx, ry, 1]`), Y ∈ ℝ^{N×2} (lignes `[ax, ay]`).
    /// On résout `A = (X^T X)^{-1} X^T Y` pour chaque colonne de Y. La matrice
    /// `X^T X` est symétrique 3×3, on l'inverse par cofacteurs.
    private func fitAffine(_ samples: [Sample]) -> AffineParams? {
        var sxx = 0.0, sxy = 0.0, sx = 0.0
        var syy = 0.0, sy = 0.0
        var n = 0.0
        var sxax = 0.0, syax = 0.0, sax = 0.0
        var sxay = 0.0, syay = 0.0, say = 0.0

        for s in samples {
            sxx += s.rx * s.rx
            sxy += s.rx * s.ry
            sx  += s.rx
            syy += s.ry * s.ry
            sy  += s.ry
            n   += 1
            sxax += s.rx * s.ax
            syax += s.ry * s.ax
            sax  += s.ax
            sxay += s.rx * s.ay
            syay += s.ry * s.ay
            say  += s.ay
        }

        // X^T X est symétrique :
        //   [sxx  sxy  sx ]
        //   [sxy  syy  sy ]
        //   [sx   sy   n  ]
        let det =
            sxx * (syy * n - sy * sy)
          - sxy * (sxy * n - sy * sx)
          + sx  * (sxy * sy - syy * sx)
        guard abs(det) > 1e-6 else { return nil }
        let invDet = 1.0 / det

        // Inverse par cofacteurs (matrice symétrique → inverse symétrique).
        let i00 =  (syy * n - sy * sy)  * invDet
        let i01 = -(sxy * n - sy * sx)  * invDet
        let i02 =  (sxy * sy - syy * sx) * invDet
        let i11 =  (sxx * n - sx * sx)  * invDet
        let i12 = -(sxx * sy - sxy * sx) * invDet
        let i22 =  (sxx * syy - sxy * sxy) * invDet
        // i10 = i01, i20 = i02, i21 = i12 (symétrie)

        // A = (X^T X)^{-1} · X^T Y, colonne par colonne.
        let m00 = i00 * sxax + i01 * syax + i02 * sax
        let m01 = i01 * sxax + i11 * syax + i12 * sax
        let tX  = i02 * sxax + i12 * syax + i22 * sax

        let m10 = i00 * sxay + i01 * syay + i02 * say
        let m11 = i01 * sxay + i11 * syay + i12 * say
        let tY  = i02 * sxay + i12 * syay + i22 * say

        return AffineParams(m00: m00, m01: m01, tx: tX, m10: m10, m11: m11, ty: tY)
    }
}
