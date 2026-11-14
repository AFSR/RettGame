import Foundation
import CoreGraphics
import Observation

/// Calibrateur du regard — **version MLP personnalisé**.
///
/// Remplace la régression quadratique par un petit réseau de neurones
/// (`GazeMLP`, 2 couches cachées de 16 et 8 neurones, ReLU, sortie
/// linéaire) entraîné sur les samples de calibration de l'utilisateur
/// courant. Prend en entrée un vecteur de 9 features au lieu de juste
/// les coordonnées ARKit — intégrer la pose de la tête, la position de
/// la pupille Vision, et les blinks donne au modèle beaucoup plus
/// d'informations pour apprendre le mapping personnel à cet enfant.
///
/// **Pipeline runtime** :
/// 1. `ARFaceViewController` calcule les 9 features à chaque frame et
///    appelle `updateFeatures(...)`.
/// 2. Les game VMs appellent `apply(_ raw:)` (API inchangée pour la
///    compat). Le paramètre `raw` est ignoré : le MLP fait son
///    inférence sur le vecteur de features caché.
/// 3. Si aucun modèle n'a encore été entraîné (< 9 samples), `apply`
///    retourne `raw` — fallback vers la pipeline ARKit directe.
///
/// **Pipeline calibration** :
/// 1. Chaque frame met à jour une EMA (α=0.10) des features pour
///    lisser le bruit instantané.
/// 2. Le tap du parent appelle `addSample(target:)` qui enregistre
///    `(features EMA, position cible)`.
/// 3. L'entraînement du MLP est relancé en arrière-plan (background
///    queue) à chaque nouveau sample ≥ 9 : 500 epochs max, early stop
///    à MSE < 0.0005, L2 regularization.
///
/// **Persistance** : seuls les samples sont sauvegardés en
/// `UserDefaults`. Le modèle est ré-entraîné à chaque lancement de
/// l'app depuis les samples persistés — garantit la compatibilité
/// future si l'architecture du MLP change.
@Observable
final class GazeCalibrator {
    static let shared = GazeCalibrator()

    /// Nombre fixe de features attendues. Doit matcher ce qu'envoie
    /// `ARFaceViewController.updateFeatures(_:)`.
    static let featureCount = 9

    struct Sample: Codable, Equatable {
        let features: [Double]  // 9 valeurs
        let target: [Double]    // 2 valeurs (x, y normalisées ∈ [0, 1])
    }

    private var samples: [Sample] = []
    private let maxSamples: Int
    /// Bump v4 → v5 : format storage changé (features vecteur 9D au lieu
    /// du couple raw/actual en pixels).
    private let persistenceKey = "afsr.eyegame.calibration.v5"

    // Thread-safety : `mlp` est écrit en background (training), lu en
    // main thread (inférence).
    private let lock = NSLock()
    private var mlp: GazeMLP?

    // Features courantes, mises à jour à 60 Hz depuis le main thread.
    private var _latestFeatures: [Double] = Array(repeating: 0, count: featureCount)
    private var _canvasSize: CGSize = CGSize(width: 1, height: 1)

    // EMA des features pour l'enregistrement des samples (plus propre
    // qu'un instantané bruité).
    private var _emaFeatures: [Double] = Array(repeating: 0, count: featureCount)
    private var _emaInitialized = false
    private let emaAlpha: Double = 0.10

    private var _isTrained: Bool = false
    private var _trainingLoss: Double = 0
    private var _isTraining: Bool = false

    // MARK: - API publique

    var samplesCount: Int { samples.count }
    /// `true` quand un modèle entraîné est disponible et utilisé.
    var isTrained: Bool { _isTrained }
    /// Dernière MSE de training (normalisée [0, 1] par axe).
    var trainingLoss: Double { _trainingLoss }
    /// `true` pendant qu'un training est en cours sur la background queue.
    var isTraining: Bool { _isTraining }
    /// Compat diagnostic : "gain x/y" n'a plus de sens en MLP, on
    /// affiche une valeur indicative (0 = pas de modèle, 1 = modèle prêt).
    var m00: CGFloat { _isTrained ? 1 : 0 }
    var m11: CGFloat { _isTrained ? 1 : 0 }

    init(maxSamples: Int = 200) {
        self.maxSamples = maxSamples
        load()
        if samples.count >= 9 {
            scheduleTraining()
        }
    }

    // MARK: - Features update (60 Hz)

    /// Appelé par `ARFaceViewController` à chaque frame avec le vecteur de
    /// features et la taille du canvas courant. Met à jour aussi l'EMA.
    func updateFeatures(_ features: [Double], canvasSize: CGSize) {
        guard features.count == Self.featureCount else { return }
        _latestFeatures = features
        _canvasSize = canvasSize

        if _emaInitialized {
            for i in 0..<features.count {
                _emaFeatures[i] = emaAlpha * features[i] + (1 - emaAlpha) * _emaFeatures[i]
            }
        } else {
            _emaFeatures = features
            _emaInitialized = true
        }
    }

    /// Reset l'EMA — à appeler entre cibles de calibration pour que le
    /// sample N+1 ne soit pas contaminé par l'historique de la cible N.
    func resetEMA() {
        _emaInitialized = false
    }

    // MARK: - Inférence (appelée par les game VMs)

    /// Retourne la position écran prédite par le MLP à partir du vecteur
    /// de features courant. Le paramètre `raw` est gardé pour la
    /// rétrocompat de l'API mais n'est utilisé que comme fallback tant
    /// qu'aucun modèle n'est entraîné.
    func apply(_ raw: CGPoint) -> CGPoint {
        lock.lock()
        let model = mlp
        lock.unlock()
        guard let model else { return raw }

        let pred = model.predict(_latestFeatures)
        let w = _canvasSize.width
        let h = _canvasSize.height
        return CGPoint(
            x: CGFloat(pred[0]) * w,
            y: CGFloat(pred[1]) * h
        )
    }

    // MARK: - Calibration (appelée par la GazeCalibrationView)

    /// Enregistre un sample en utilisant les features EMA actuelles et
    /// la position écran de la cible (normalisée par le canvas).
    func addSample(target: CGPoint) {
        guard _emaInitialized else { return }
        let normTarget = [
            Double(target.x / _canvasSize.width),
            Double(target.y / _canvasSize.height)
        ]
        samples.append(Sample(features: _emaFeatures, target: normTarget))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        save()

        if samples.count >= 9 {
            scheduleTraining()
        }
    }

    func reset() {
        samples.removeAll()
        lock.lock()
        mlp = nil
        lock.unlock()
        _isTrained = false
        _trainingLoss = 0
        save()
    }

    // MARK: - Training (background)

    private func scheduleTraining() {
        // Snapshot des samples pour entraîner sans tenir de lock côté main.
        let batch = samples.map { (x: $0.features, y: $0.target) }
        _isTraining = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var model = GazeMLP(inputSize: Self.featureCount, outputSize: 2)
            let lr = 0.05
            let l2 = 0.001
            let maxEpochs = 500
            var lastLoss = 0.0
            for _ in 0..<maxEpochs {
                lastLoss = model.trainOneEpoch(samples: batch, learningRate: lr, l2: l2)
                if lastLoss < 0.0005 { break }
            }
            self.lock.lock()
            self.mlp = model
            self.lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?._trainingLoss = lastLoss
                self?._isTrained = true
                self?._isTraining = false
            }
        }
    }

    // MARK: - Persistance

    private func save() {
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data)
        else { return }
        samples = decoded.filter { $0.features.count == Self.featureCount && $0.target.count == 2 }
        if samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
    }
}
