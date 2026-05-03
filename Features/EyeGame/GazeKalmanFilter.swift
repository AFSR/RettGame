import Foundation
import CoreGraphics
import QuartzCore

/// Filtre de Kalman 2D pour lisser la position du regard.
///
/// Modèle à accélération gaussienne : état `[x, y, vx, vy]`, mesure `[x, y]`.
///
/// Deux paramètres règlent le comportement :
///
/// 1. **`smoothingStrength` ∈ [0, 1]** — contrôlé par l'utilisateur dans les
///    Réglages. 0 = réactif (très peu de lissage), 1 = très lisse.
/// 2. **Nombre d'échantillons de calibration** — le bruit de mesure R diminue
///    quand on a plus de points, donc le filtre fait plus confiance à la mesure
///    quand la calibration est stable.
///
/// Les deux effets se multiplient : à strength=0, R est déjà très faible, le
/// filtre est quasi transparent. À strength=1, R est multiplié par ~10 et le
/// filtre lisse fortement.
final class GazeKalmanFilter {

    // MARK: - Tuning baseline (avant application de smoothingStrength)

    /// σ de mesure avec aucune calibration (pixels).
    private let sigmaMeasureHighBase: Double = 60.0
    /// σ de mesure quand la calibration est stable (≥ samplesForFullConfidence).
    private let sigmaMeasureLowBase: Double = 8.0
    /// Nombre d'échantillons pour atteindre la confiance maximale.
    private let samplesForFullConfidence: Double = 10.0
    /// σ d'accélération aléatoire (pixels/s²) — plus élevé = filtre plus réactif aux changements.
    private let sigmaAcceleration: Double = 4000.0

    // MARK: - Config runtime

    /// 0 = aucun lissage (filtre bypassé), 1 = lissage maximal.
    var smoothingStrength: Double = 0.4 {
        didSet {
            smoothingStrength = max(0, min(1, smoothingStrength))
            recomputeR()
        }
    }

    /// Si faux, le filtre est complètement bypassé (retourne la mesure brute).
    var enabled: Bool = true

    // MARK: - State

    private var state: [Double] = [0, 0, 0, 0]
    private var P: [[Double]] = GazeKalmanFilter.diag([1000, 1000, 1000, 1000])
    private var R: [[Double]] = [[1, 0], [0, 1]]
    private var lastTimestamp: CFTimeInterval?
    private var initialized = false
    private var lastSampleCount: Int = 0

    init() {
        recomputeR()
    }

    // MARK: - Public API

    func reset() {
        state = [0, 0, 0, 0]
        P = GazeKalmanFilter.diag([1000, 1000, 1000, 1000])
        lastTimestamp = nil
        initialized = false
    }

    /// Met à jour la confiance du filtre en fonction du nombre d'échantillons de calibration.
    func setCalibrationConfidence(sampleCount: Int) {
        lastSampleCount = sampleCount
        recomputeR()
    }

    private func recomputeR() {
        let factor = min(Double(lastSampleCount) / samplesForFullConfidence, 1.0)
        // Échelle entre High (peu de calibration) et Low (calibration stable)
        let baseSigma = sigmaMeasureHighBase - (sigmaMeasureHighBase - sigmaMeasureLowBase) * factor
        // Amplification par smoothingStrength : σ_final = baseSigma · (1 + 3·strength).
        // À strength=0 : σ = baseSigma. À strength=1 : σ = 4·baseSigma → variance ×16.
        let sigma = baseSigma * (1.0 + 3.0 * smoothingStrength)
        let r = sigma * sigma
        R = [[r, 0], [0, r]]
    }

    /// Applique une étape prédiction + mise à jour et retourne la position lissée.
    /// Si `enabled == false`, retourne directement la mesure.
    func filter(measurement: CGPoint) -> CGPoint {
        guard enabled else {
            initialized = false
            return measurement
        }
        let now = CACurrentMediaTime()
        let dt: Double
        if let last = lastTimestamp {
            dt = max(0.001, min(0.1, now - last))
        } else {
            dt = 1.0 / 60.0
        }
        lastTimestamp = now

        if !initialized {
            state = [Double(measurement.x), Double(measurement.y), 0, 0]
            initialized = true
            return measurement
        }

        predict(dt: dt)
        update(measurement: measurement)
        return CGPoint(x: state[0], y: state[1])
    }

    // MARK: - Kalman steps

    private func predict(dt: Double) {
        state = [
            state[0] + dt * state[2],
            state[1] + dt * state[3],
            state[2],
            state[3]
        ]
        let F: [[Double]] = [
            [1, 0, dt, 0],
            [0, 1, 0, dt],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ]
        let FP = Self.mul(F, P)
        let FPFt = Self.mul(FP, Self.transpose(F))
        let Q = processNoise(dt: dt)
        P = Self.add(FPFt, Q)
    }

    private func processNoise(dt: Double) -> [[Double]] {
        let sa2 = sigmaAcceleration * sigmaAcceleration
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt3 * dt
        return [
            [dt4 / 4 * sa2, 0, dt3 / 2 * sa2, 0],
            [0, dt4 / 4 * sa2, 0, dt3 / 2 * sa2],
            [dt3 / 2 * sa2, 0, dt2 * sa2, 0],
            [0, dt3 / 2 * sa2, 0, dt2 * sa2]
        ]
    }

    private func update(measurement: CGPoint) {
        let innovation: [Double] = [
            Double(measurement.x) - state[0],
            Double(measurement.y) - state[1]
        ]
        let S: [[Double]] = [
            [P[0][0] + R[0][0], P[0][1] + R[0][1]],
            [P[1][0] + R[1][0], P[1][1] + R[1][1]]
        ]
        let det = S[0][0] * S[1][1] - S[0][1] * S[1][0]
        guard abs(det) > 1e-9 else { return }
        let Sinv: [[Double]] = [
            [ S[1][1] / det, -S[0][1] / det],
            [-S[1][0] / det,  S[0][0] / det]
        ]
        var K = [[Double]](repeating: [0, 0], count: 4)
        for i in 0..<4 {
            for j in 0..<2 {
                K[i][j] = P[i][0] * Sinv[0][j] + P[i][1] * Sinv[1][j]
            }
        }
        for i in 0..<4 {
            state[i] += K[i][0] * innovation[0] + K[i][1] * innovation[1]
        }
        var newP = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for i in 0..<4 {
            for j in 0..<4 {
                var sum = P[i][j]
                sum -= K[i][0] * P[0][j] + K[i][1] * P[1][j]
                newP[i][j] = sum
            }
        }
        P = newP
    }

    // MARK: - Matrix helpers

    private static func diag(_ values: [Double]) -> [[Double]] {
        var m = [[Double]](repeating: [Double](repeating: 0, count: values.count), count: values.count)
        for i in 0..<values.count { m[i][i] = values[i] }
        return m
    }

    private static func transpose(_ a: [[Double]]) -> [[Double]] {
        let rows = a.count
        let cols = a[0].count
        var t = [[Double]](repeating: [Double](repeating: 0, count: rows), count: cols)
        for i in 0..<rows { for j in 0..<cols { t[j][i] = a[i][j] } }
        return t
    }

    private static func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        let rows = a.count
        let inner = b.count
        let cols = b[0].count
        var out = [[Double]](repeating: [Double](repeating: 0, count: cols), count: rows)
        for i in 0..<rows {
            for j in 0..<cols {
                var sum = 0.0
                for k in 0..<inner { sum += a[i][k] * b[k][j] }
                out[i][j] = sum
            }
        }
        return out
    }

    private static func add(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        let rows = a.count
        let cols = a[0].count
        var out = [[Double]](repeating: [Double](repeating: 0, count: cols), count: rows)
        for i in 0..<rows { for j in 0..<cols { out[i][j] = a[i][j] + b[i][j] } }
        return out
    }
}
