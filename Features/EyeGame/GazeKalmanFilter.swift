import Foundation
import CoreGraphics
import QuartzCore
import simd

/// Filtre de Kalman 2D pour lisser la position du regard.
///
/// Modèle à accélération gaussienne : état `[x, y, vx, vy]`, mesure `[x, y]`.
///
/// Deux paramètres règlent le comportement :
/// - **`smoothingStrength` ∈ [0, 1]** — réglage utilisateur (0 = réactif, 1 = lisse).
/// - **Nombre d'échantillons de calibration** — la variance de mesure baisse
///   avec plus de points, le filtre fait davantage confiance à la mesure quand
///   la calibration est stable.
///
/// Implémentation : matrices fixes (`simd_double4x4`, scalaires pour les blocs
/// 2×2) allouées sur la pile, opérations vectorisées par le matériel — `filter()`
/// est appelé à 60 Hz et n'alloue plus de mémoire heap après l'init.
final class GazeKalmanFilter {

    // MARK: - Tuning baseline

    private let sigmaMeasureHighBase: Double = 60.0
    private let sigmaMeasureLowBase: Double = 8.0
    private let samplesForFullConfidence: Double = 10.0
    private let sigmaAcceleration: Double = 4000.0

    // MARK: - Config runtime

    var smoothingStrength: Double = 0.4 {
        didSet {
            smoothingStrength = max(0, min(1, smoothingStrength))
            recomputeR()
        }
    }

    var enabled: Bool = true

    // MARK: - State

    private var state: SIMD4<Double> = .zero
    private var P: simd_double4x4 = simd_double4x4(diagonal: SIMD4(1000, 1000, 1000, 1000))
    private var measurementVariance: Double = 1
    private var lastTimestamp: CFTimeInterval?
    private var initialized = false
    private var lastSampleCount: Int = 0

    init() {
        recomputeR()
    }

    // MARK: - Public API

    func reset() {
        state = .zero
        P = simd_double4x4(diagonal: SIMD4(1000, 1000, 1000, 1000))
        lastTimestamp = nil
        initialized = false
    }

    func setCalibrationConfidence(sampleCount: Int) {
        lastSampleCount = sampleCount
        recomputeR()
    }

    private func recomputeR() {
        let factor = min(Double(lastSampleCount) / samplesForFullConfidence, 1.0)
        let baseSigma = sigmaMeasureHighBase - (sigmaMeasureHighBase - sigmaMeasureLowBase) * factor
        let sigma = baseSigma * (1.0 + 3.0 * smoothingStrength)
        measurementVariance = sigma * sigma
    }

    /// Applique une étape prédiction + mise à jour et retourne la position lissée.
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
            state = SIMD4(Double(measurement.x), Double(measurement.y), 0, 0)
            initialized = true
            return measurement
        }

        predict(dt: dt)
        update(measurement: SIMD2(Double(measurement.x), Double(measurement.y)))
        return CGPoint(x: state.x, y: state.y)
    }

    // MARK: - Kalman steps

    /// `simd_double4x4` est column-major : on liste les 4 colonnes successives.
    /// Matrice de transition F ([1 0 dt 0 ; 0 1 0 dt ; 0 0 1 0 ; 0 0 0 1]).
    @inline(__always)
    private func transitionMatrix(dt: Double) -> simd_double4x4 {
        simd_double4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(dt, 0, 1, 0),
            SIMD4(0, dt, 0, 1)
        )
    }

    @inline(__always)
    private func processNoise(dt: Double) -> simd_double4x4 {
        let sa2 = sigmaAcceleration * sigmaAcceleration
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt3 * dt
        let q11 = dt4 * 0.25 * sa2
        let q13 = dt3 * 0.5 * sa2
        let q33 = dt2 * sa2
        return simd_double4x4(
            SIMD4(q11, 0, q13, 0),
            SIMD4(0, q11, 0, q13),
            SIMD4(q13, 0, q33, 0),
            SIMD4(0, q13, 0, q33)
        )
    }

    private func predict(dt: Double) {
        let F = transitionMatrix(dt: dt)
        state = F * state
        // P = F · P · F^T + Q
        P = F * P * F.transpose + processNoise(dt: dt)
    }

    /// Étape de mise à jour. H = [I₂ | 0₂] (mesure x, y depuis l'état).
    /// On exploite la structure de H pour ne jamais matérialiser de matrice 2×4.
    private func update(measurement: SIMD2<Double>) {
        // Innovation y = z - H·x.
        let innovation = measurement - SIMD2(state.x, state.y)

        // Accès column-major : P[col][row] = P_{row, col} (notation math).
        let pCol0 = P[0]
        let pCol1 = P[1]

        // S = H·P·H^T + R = top-left 2×2 de P + r·I.
        let s00 = pCol0[0] + measurementVariance       // P_{0,0} + r
        let s11 = pCol1[1] + measurementVariance       // P_{1,1} + r
        let s01 = pCol1[0]                              // P_{0,1}
        let s10 = pCol0[1]                              // P_{1,0}

        let det = s00 * s11 - s01 * s10
        guard abs(det) > 1e-9 else { return }
        let invDet = 1.0 / det
        // S^{-1} (2×2)
        let si00 =  s11 * invDet
        let si01 = -s01 * invDet
        let si10 = -s10 * invDet
        let si11 =  s00 * invDet

        // K = P · H^T · S^{-1} (4×2). PH^T = 2 premières colonnes de P.
        // K[:, 0] = pCol0 · si00 + pCol1 · si10
        // K[:, 1] = pCol0 · si01 + pCol1 · si11
        let k0 = pCol0 * si00 + pCol1 * si10
        let k1 = pCol0 * si01 + pCol1 * si11

        // x ← x + K · y
        state = state + k0 * innovation.x + k1 * innovation.y

        // P ← P − K · H · P. (K·H·P)_{:, j} = k0 · P_{0, j} + k1 · P_{1, j}
        //                                  = k0 · P[j][0] + k1 · P[j][1]
        var newP = P
        for j in 0..<4 {
            let pColJ = P[j]
            newP[j] = pColJ - (k0 * pColJ[0] + k1 * pColJ[1])
        }
        P = newP
    }
}
