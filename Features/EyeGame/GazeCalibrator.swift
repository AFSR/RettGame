import Foundation
import CoreGraphics

/// Calibrateur du regard.
///
/// Maintient une liste de paires `(raw, actual)` où `raw` est le point fourni par
/// ARKit (projection de `lookAtPoint`) et `actual` est la position réelle à laquelle
/// l'enfant regarde (fournie par un tap du parent sur la cible).
///
/// À partir des échantillons, on fait deux régressions linéaires indépendantes :
/// `actual_x = scaleX * raw_x + offsetX` et pareil pour y. C'est une approximation
/// simple mais robuste : ça corrige offset, échelle et inversion d'axe en même temps.
///
/// Les échantillons sont persistés dans `UserDefaults` pour survivre entre les
/// lancements de l'app.
final class GazeCalibrator {
    private struct Sample: Codable { let rx: Double; let ry: Double; let ax: Double; let ay: Double }

    private var samples: [Sample] = []
    private let maxSamples: Int
    /// Versionnée :
    /// - v1 : lookAtPoint via ARSCNView.projectPoint (compressé près du centre)
    /// - v2 : ray-plane intersection via eye transforms en world space (sign d'axe Z incertain)
    /// - v3 : combinaison des 8 blendShapes oculaires en vecteur 2D normalisé (signal stable
    ///        et linéaire, indépendant de la distance face-écran et de l'orientation device)
    /// Bumper la clé efface implicitement les calibrations apprises sur les signaux antérieurs.
    private let persistenceKey = "afsr.eyegame.calibration.samples.v3"

    /// Transformation affine 1D par axe : apply(p) = (scaleX*p.x + offsetX, scaleY*p.y + offsetY).
    private(set) var scaleX: CGFloat = 1
    private(set) var offsetX: CGFloat = 0
    private(set) var scaleY: CGFloat = 1
    private(set) var offsetY: CGFloat = 0

    init(maxSamples: Int = 30) {
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
        scaleX = 1; offsetX = 0
        scaleY = 1; offsetY = 0
        save()
    }

    /// Applique la transformation au point brut. Si moins de 2 échantillons, retourne `raw`.
    func apply(_ raw: CGPoint) -> CGPoint {
        guard samples.count >= 2 else { return raw }
        return CGPoint(
            x: raw.x * scaleX + offsetX,
            y: raw.y * scaleY + offsetY
        )
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(samples)
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            // échec silencieux — la calibration en mémoire reste utilisable
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

    // MARK: - Regression

    private func recompute() {
        guard samples.count >= 2 else {
            scaleX = 1; offsetX = 0
            scaleY = 1; offsetY = 0
            return
        }
        let rawsX = samples.map { $0.rx }
        let actsX = samples.map { $0.ax }
        let rawsY = samples.map { $0.ry }
        let actsY = samples.map { $0.ay }

        let (sx, ox) = linearFit(xs: rawsX, ys: actsX)
        let (sy, oy) = linearFit(xs: rawsY, ys: actsY)
        scaleX = CGFloat(sx); offsetX = CGFloat(ox)
        scaleY = CGFloat(sy); offsetY = CGFloat(oy)
    }

    /// Régression linéaire ordinaire. Retourne (slope, intercept) qui minimisent MSE.
    /// Si la variance de `xs` est trop faible, retourne (1, moy(ys) - moy(xs)).
    private func linearFit(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double) {
        let n = Double(xs.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let meanX = sumX / n
        let meanY = sumY / n
        var num = 0.0
        var den = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX
            num += dx * (ys[i] - meanY)
            den += dx * dx
        }
        if den < 1e-6 {
            return (1.0, meanY - meanX)
        }
        let slope = num / den
        let intercept = meanY - slope * meanX
        return (slope, intercept)
    }
}
