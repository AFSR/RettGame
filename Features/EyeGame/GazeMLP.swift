import Foundation

/// Petit réseau de neurones feedforward pur Swift, dimensionné pour
/// l'apprentissage on-device d'un mapping (features → position écran) à
/// partir des 9-25 samples de calibration d'un utilisateur donné.
///
/// Architecture : **inputSize → 16 → 8 → outputSize**, activation ReLU
/// entre les couches cachées, sortie linéaire (régression). Nombre total
/// de paramètres ~200 pour `inputSize=9, outputSize=2`, ce qui reste
/// gérable pour 10-25 samples avec L2 régularisation + early stopping.
///
/// Les hyperparamètres (couches, taille, lr, régularisation) ont été
/// calés pour converger en ~500 ms sur iPad Air M3 avec 20 samples —
/// l'entraînement est appelé après chaque tap de calibration, sans
/// bloquer l'UI (background queue).
struct GazeMLP: Codable {

    // MARK: - Dimensions

    let inputSize: Int
    let hiddenSize1: Int
    let hiddenSize2: Int
    let outputSize: Int

    // MARK: - Paramètres entraînables

    var w1: [[Double]]  // [hiddenSize1 × inputSize]
    var b1: [Double]    // [hiddenSize1]
    var w2: [[Double]]  // [hiddenSize2 × hiddenSize1]
    var b2: [Double]    // [hiddenSize2]
    var w3: [[Double]]  // [outputSize × hiddenSize2]
    var b3: [Double]    // [outputSize]

    // MARK: - Init

    init(inputSize: Int, hiddenSize1: Int = 16, hiddenSize2: Int = 8, outputSize: Int) {
        self.inputSize = inputSize
        self.hiddenSize1 = hiddenSize1
        self.hiddenSize2 = hiddenSize2
        self.outputSize = outputSize

        // Initialisation He (adaptée à ReLU) : scale = sqrt(2 / fan_in)
        var rng = SystemRandomNumberGenerator()
        w1 = Self.randomMatrix(rows: hiddenSize1, cols: inputSize,
                               scale: (2.0 / Double(inputSize)).squareRoot(), rng: &rng)
        b1 = Array(repeating: 0, count: hiddenSize1)
        w2 = Self.randomMatrix(rows: hiddenSize2, cols: hiddenSize1,
                               scale: (2.0 / Double(hiddenSize1)).squareRoot(), rng: &rng)
        b2 = Array(repeating: 0, count: hiddenSize2)
        w3 = Self.randomMatrix(rows: outputSize, cols: hiddenSize2,
                               scale: (2.0 / Double(hiddenSize2)).squareRoot(), rng: &rng)
        b3 = Array(repeating: 0, count: outputSize)
    }

    // MARK: - Forward

    /// Inférence seule. Utilisée au runtime, 60 Hz.
    func predict(_ x: [Double]) -> [Double] {
        forward(x).output
    }

    /// Forward complet qui retourne aussi les activations intermédiaires
    /// (nécessaires pour la backprop pendant l'entraînement).
    func forward(_ x: [Double]) -> (h1: [Double], h2: [Double], output: [Double]) {
        // Couche 1 : h1 = ReLU(W1 · x + b1)
        var h1 = b1
        for i in 0..<hiddenSize1 {
            var acc = b1[i]
            for j in 0..<inputSize { acc += w1[i][j] * x[j] }
            h1[i] = max(0, acc)
        }
        // Couche 2 : h2 = ReLU(W2 · h1 + b2)
        var h2 = b2
        for i in 0..<hiddenSize2 {
            var acc = b2[i]
            for j in 0..<hiddenSize1 { acc += w2[i][j] * h1[j] }
            h2[i] = max(0, acc)
        }
        // Couche de sortie : y = W3 · h2 + b3 (linéaire, régression)
        var output = b3
        for i in 0..<outputSize {
            var acc = b3[i]
            for j in 0..<hiddenSize2 { acc += w3[i][j] * h2[j] }
            output[i] = acc
        }
        return (h1, h2, output)
    }

    // MARK: - Entraînement

    /// Un pas de SGD (full batch) sur l'ensemble des samples. Retourne la
    /// MSE moyenne sur le batch. L2 regularization appliquée aux poids
    /// (pas aux biais) avec coefficient `l2`.
    @discardableResult
    mutating func trainOneEpoch(samples: [(x: [Double], y: [Double])],
                                 learningRate: Double,
                                 l2: Double) -> Double {
        // Gradients accumulés sur tout le batch.
        var gW1 = Self.zerosMatrix(rows: hiddenSize1, cols: inputSize)
        var gB1 = Array(repeating: 0.0, count: hiddenSize1)
        var gW2 = Self.zerosMatrix(rows: hiddenSize2, cols: hiddenSize1)
        var gB2 = Array(repeating: 0.0, count: hiddenSize2)
        var gW3 = Self.zerosMatrix(rows: outputSize, cols: hiddenSize2)
        var gB3 = Array(repeating: 0.0, count: outputSize)

        var totalLoss = 0.0

        for (x, y) in samples {
            let (h1, h2, pred) = forward(x)

            // Gradient de la MSE au niveau de la sortie : dL/dpred = 2(pred - y)
            var dOut = Array(repeating: 0.0, count: outputSize)
            for i in 0..<outputSize {
                let err = pred[i] - y[i]
                totalLoss += err * err
                dOut[i] = 2 * err
            }

            // Backprop couche 3 (output). Accumule dW3, dB3, dH2.
            var dH2 = Array(repeating: 0.0, count: hiddenSize2)
            for i in 0..<outputSize {
                gB3[i] += dOut[i]
                for j in 0..<hiddenSize2 {
                    gW3[i][j] += dOut[i] * h2[j]
                    dH2[j]   += dOut[i] * w3[i][j]
                }
            }
            // ReLU' : dH2 = 0 là où h2 était <= 0
            for j in 0..<hiddenSize2 where h2[j] <= 0 { dH2[j] = 0 }

            // Backprop couche 2.
            var dH1 = Array(repeating: 0.0, count: hiddenSize1)
            for i in 0..<hiddenSize2 {
                gB2[i] += dH2[i]
                for j in 0..<hiddenSize1 {
                    gW2[i][j] += dH2[i] * h1[j]
                    dH1[j]   += dH2[i] * w2[i][j]
                }
            }
            for j in 0..<hiddenSize1 where h1[j] <= 0 { dH1[j] = 0 }

            // Backprop couche 1.
            for i in 0..<hiddenSize1 {
                gB1[i] += dH1[i]
                for j in 0..<inputSize {
                    gW1[i][j] += dH1[i] * x[j]
                }
            }
        }

        // Moyennage sur le batch + L2 reg + update SGD.
        let n = Double(samples.count)
        for i in 0..<hiddenSize1 {
            b1[i] -= learningRate * (gB1[i] / n)
            for j in 0..<inputSize {
                w1[i][j] -= learningRate * (gW1[i][j] / n + l2 * w1[i][j])
            }
        }
        for i in 0..<hiddenSize2 {
            b2[i] -= learningRate * (gB2[i] / n)
            for j in 0..<hiddenSize1 {
                w2[i][j] -= learningRate * (gW2[i][j] / n + l2 * w2[i][j])
            }
        }
        for i in 0..<outputSize {
            b3[i] -= learningRate * (gB3[i] / n)
            for j in 0..<hiddenSize2 {
                w3[i][j] -= learningRate * (gW3[i][j] / n + l2 * w3[i][j])
            }
        }

        return totalLoss / (n * Double(outputSize))
    }

    // MARK: - Utils

    private static func randomMatrix(rows: Int, cols: Int, scale: Double,
                                      rng: inout SystemRandomNumberGenerator) -> [[Double]] {
        var m = Array(repeating: Array(repeating: 0.0, count: cols), count: rows)
        for i in 0..<rows {
            for j in 0..<cols {
                m[i][j] = Double.random(in: -1...1, using: &rng) * scale
            }
        }
        return m
    }

    private static func zerosMatrix(rows: Int, cols: Int) -> [[Double]] {
        Array(repeating: Array(repeating: 0.0, count: cols), count: rows)
    }
}
