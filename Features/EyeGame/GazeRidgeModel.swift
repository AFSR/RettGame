import Foundation

/// Régression linéaire ridge multi-sorties, features standardisées.
///
///     y_k = ȳ_k + Σ_j w_kj · (x_j − μ_j) / σ_j
///
/// Entraînement en forme fermée (équations normales + Cholesky) : pas d'itération,
/// pas de point de départ aléatoire, aucune divergence possible. Avec 4 features et
/// 2 sorties on estime 8 poids + 2 offsets, ce qui reste bien posé avec les 9 à
/// 200 samples d'une calibration (un MLP 9→16→8→2 en avait ~200 et surapprenait).
///
/// La standardisation met les features (mètres, coefficients [0, 1]…) à la même
/// échelle : la pénalité ridge les traite alors équitablement, et une feature
/// constante est neutralisée (écart-type forcé à 1, poids nul).
struct GazeRidgeModel {
    let featureCount: Int
    let outputCount: Int
    private let means: [Double]
    private let stds: [Double]
    private let outputMeans: [Double]
    /// weights[sortie][feature]
    private let weights: [[Double]]

    private init(featureCount: Int, outputCount: Int, means: [Double], stds: [Double],
                 outputMeans: [Double], weights: [[Double]]) {
        self.featureCount = featureCount
        self.outputCount = outputCount
        self.means = means
        self.stds = stds
        self.outputMeans = outputMeans
        self.weights = weights
    }

    func predict(_ x: [Double]) -> [Double] {
        guard x.count == featureCount else { return outputMeans }
        var out = outputMeans
        for c in 0..<outputCount {
            var acc = outputMeans[c]
            for j in 0..<featureCount {
                acc += weights[c][j] * (x[j] - means[j]) / stds[j]
            }
            out[c] = acc
        }
        return out
    }

    /// Ajuste le modèle. `lambda` est le coefficient ridge (en unités standardisées).
    /// Retourne nil s'il y a moins de samples que de paramètres par sortie.
    static func fit(samples: [(x: [Double], y: [Double])], lambda: Double) -> GazeRidgeModel? {
        guard let first = samples.first else { return nil }
        let d = first.x.count
        let k = first.y.count
        let n = samples.count
        guard d > 0, k > 0, n >= d + 1 else { return nil }
        let nD = Double(n)

        var means = [Double](repeating: 0, count: d)
        var outputMeans = [Double](repeating: 0, count: k)
        for s in samples {
            for j in 0..<d { means[j] += s.x[j] }
            for c in 0..<k { outputMeans[c] += s.y[c] }
        }
        for j in 0..<d { means[j] /= nD }
        for c in 0..<k { outputMeans[c] /= nD }

        var stds = [Double](repeating: 0, count: d)
        for s in samples {
            for j in 0..<d {
                let dx = s.x[j] - means[j]
                stds[j] += dx * dx
            }
        }
        for j in 0..<d {
            let sd = (stds[j] / nD).squareRoot()
            stds[j] = sd > 1e-9 ? sd : 1
        }

        // A = XsᵀXs + λI   (d × d)      B = XsᵀYc   (d × k)
        var a = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        var b = [[Double]](repeating: [Double](repeating: 0, count: k), count: d)
        var xs = [Double](repeating: 0, count: d)
        for s in samples {
            for j in 0..<d { xs[j] = (s.x[j] - means[j]) / stds[j] }
            for i in 0..<d {
                for j in 0..<d { a[i][j] += xs[i] * xs[j] }
                for c in 0..<k { b[i][c] += xs[i] * (s.y[c] - outputMeans[c]) }
            }
        }
        for i in 0..<d { a[i][i] += lambda }

        guard let l = cholesky(a) else { return nil }
        var weights = [[Double]](repeating: [Double](repeating: 0, count: d), count: k)
        for c in 0..<k {
            var rhs = [Double](repeating: 0, count: d)
            for i in 0..<d { rhs[i] = b[i][c] }
            weights[c] = solve(cholesky: l, rhs: rhs)
        }

        return GazeRidgeModel(featureCount: d, outputCount: k, means: means, stds: stds,
                              outputMeans: outputMeans, weights: weights)
    }

    // MARK: - Algèbre linéaire (petites matrices symétriques définies positives)

    /// Décomposition A = L·Lᵀ. nil si A n'est pas définie positive.
    private static func cholesky(_ a: [[Double]]) -> [[Double]]? {
        let n = a.count
        var l = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var s = a[i][j]
                for p in 0..<j { s -= l[i][p] * l[j][p] }
                if i == j {
                    if s <= 1e-12 { return nil }
                    l[i][j] = s.squareRoot()
                } else {
                    l[i][j] = s / l[j][j]
                }
            }
        }
        return l
    }

    /// Résout A·w = b connaissant L (A = L·Lᵀ) : substitution avant puis arrière.
    private static func solve(cholesky l: [[Double]], rhs b: [Double]) -> [Double] {
        let n = b.count
        var z = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = b[i]
            for j in 0..<i { s -= l[i][j] * z[j] }
            z[i] = s / l[i][i]
        }
        var w = [Double](repeating: 0, count: n)
        for ii in 0..<n {
            let i = n - 1 - ii
            var s = z[i]
            for j in (i + 1)..<n { s -= l[j][i] * w[j] }
            w[i] = s / l[i][i]
        }
        return w
    }
}
