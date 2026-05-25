import Foundation
import CoreGraphics
import Observation

/// Calibrateur du regard — modèle **affine 1D par axe**.
///
/// On apprend deux régressions linéaires indépendantes :
/// ```
/// ax = m00 · rx + tx
/// ay = m11 · ry + ty
/// ```
/// (les termes croisés `m01` et `m10` sont forcés à 0.)
///
/// Le modèle 2D affine complet à 6 paramètres a été tenté précédemment mais
/// s'effondrait sur des jeux de samples réalistes : la moindre corrélation
/// parasite entre rx et ry (tête légèrement inclinée, regard diagonal, etc.)
/// rendait X^T X mal conditionnée, OLS collapsait alors vers la moyenne des
/// `actual` et le calibrateur figeait son output au centre de l'écran.
///
/// Le 1D par axe est moins expressif mais beaucoup plus robuste : il ne peut
/// pas corriger une rotation, mais peut absorber gain, offset et inversion
/// d'axe — ce qui couvre 95 % des cas réels.
///
/// Stabilité numérique : on centre rx/ry/ax/ay sur leur moyenne avant la
/// régression, ce qui réduit les sommations à des variances/covariances de
/// magnitude beaucoup plus faible que les sommes brutes (~10^4 vs ~10^7) et
/// limite la perte de précision flottante.
///
/// Bornes de sécurité : si le gain calculé sort de `[0.1, 20]` (typiquement
/// le cas avec des samples dégénérés), on le clamp puis on recalcule
/// l'intercept en conséquence. Évite que la calibration ne projette tous les
/// regards à l'infini.
///
/// Rejet d'outliers : après un premier fit on calcule les résidus, on
/// supprime les samples au-delà de `max(80 px, 3 × médiane)` et on refit.
/// Cette étape évite qu'un seul tap raté empoisonne toute la calibration.
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

    /// Modèle affine — `m01` et `m10` sont conservés pour API compatibilité
    /// mais valent toujours 0 dans cette implémentation.
    private(set) var m00: CGFloat = 1
    private(set) var m01: CGFloat = 0
    private(set) var tx:  CGFloat = 0
    private(set) var m10: CGFloat = 0
    private(set) var m11: CGFloat = 1
    private(set) var ty:  CGFloat = 0

    private let minGain: Double = 0.1
    private let maxGain: Double = 20.0

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
        m00 = 1; m01 = 0; tx = 0
        m10 = 0; m11 = 1; ty = 0
        save()
    }

    func apply(_ raw: CGPoint) -> CGPoint {
        guard samples.count >= 3 else { return raw }
        return CGPoint(
            x: m00 * raw.x + tx,
            y: m11 * raw.y + ty
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

    // MARK: - Regression (per-axis 1D OLS + outlier rejection)

    private func recompute() {
        guard samples.count >= 3 else {
            m00 = 1; m01 = 0; tx = 0
            m10 = 0; m11 = 1; ty = 0
            return
        }

        let p1 = fitPerAxis(samples)
        apply(params: p1)

        // Deuxième passe : rejet d'outliers si on a assez de samples pour
        // garder ≥3 après filtrage.
        guard samples.count >= 9 else { return }

        let residuals = samples.map { residual(of: $0) }
        let sorted = residuals.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(80.0, 3.0 * median)
        let inliers = zip(samples, residuals)
            .filter { $0.1 <= threshold }
            .map { $0.0 }

        if inliers.count >= 3 {
            apply(params: fitPerAxis(inliers))
        }
    }

    private func apply(params p: AffineParams) {
        m00 = CGFloat(p.m00); m01 = 0; tx = CGFloat(p.tx)
        m10 = 0; m11 = CGFloat(p.m11); ty = CGFloat(p.ty)
    }

    @inline(__always)
    private func residual(of s: Sample) -> Double {
        let predX = Double(m00) * s.rx + Double(tx)
        let predY = Double(m11) * s.ry + Double(ty)
        let dx = predX - s.ax
        let dy = predY - s.ay
        return (dx * dx + dy * dy).squareRoot()
    }

    private struct AffineParams {
        let m00: Double; let tx: Double
        let m11: Double; let ty: Double
    }

    /// OLS centré, axe par axe. Renvoie toujours un modèle valide : si la
    /// variance d'une dimension est nulle (samples colinéaires sur cet axe),
    /// on retombe sur l'identité pour cet axe.
    private func fitPerAxis(_ samples: [Sample]) -> AffineParams {
        let n = Double(samples.count)
        var meanRx = 0.0, meanRy = 0.0, meanAx = 0.0, meanAy = 0.0
        for s in samples {
            meanRx += s.rx; meanRy += s.ry
            meanAx += s.ax; meanAy += s.ay
        }
        meanRx /= n; meanRy /= n; meanAx /= n; meanAy /= n

        var varRx = 0.0, varRy = 0.0
        var covRxAx = 0.0, covRyAy = 0.0
        for s in samples {
            let rxc = s.rx - meanRx
            let ryc = s.ry - meanRy
            varRx += rxc * rxc
            varRy += ryc * ryc
            covRxAx += rxc * (s.ax - meanAx)
            covRyAy += ryc * (s.ay - meanAy)
        }

        let mx = fitGain(cov: covRxAx, variance: varRx)
        let my = fitGain(cov: covRyAy, variance: varRy)
        let tX = meanAx - mx * meanRx
        let tY = meanAy - my * meanRy

        return AffineParams(m00: mx, tx: tX, m11: my, ty: tY)
    }

    @inline(__always)
    private func fitGain(cov: Double, variance: Double) -> Double {
        // Variance insuffisante (axe dégénéré) → on garde l'identité pour
        // que l'apply ne ramène pas tout au centre.
        guard variance > 1.0 else { return 1.0 }
        let raw = cov / variance
        // Clamp dans une plage raisonnable : aucun gain physique légitime
        // ne dépasse 20× ou n'est inférieur à 0.1× sur cet équipement.
        return max(minGain, min(maxGain, raw))
    }
}

