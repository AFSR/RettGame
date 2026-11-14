import Foundation
import CoreGraphics
import Observation
import UIKit

/// Calibrateur du regard : régression ridge personnalisée (`GazeRidgeModel`).
///
/// **Features** (poussées à chaque frame par `ARFaceViewController`) :
///   0, 1 : impact du rayon œil → point de fixation sur le plan de l'écran, repère caméra (m)
///   2, 3 : indices horizontal / vertical dérivés des blendShapes oculaires ARKit
/// Deux estimateurs indépendants du même regard : la régression apprend à les combiner.
/// Aucune convention d'axe ou de signe n'est codée en dur (permutation portrait/paysage,
/// miroir…) : le modèle linéaire complet les absorbe, y compris sur iPad.
///
/// **Coordonnées** : tout est exprimé dans la fenêtre, normalisé par sa taille. Les vues de
/// jeu et de calibration occupent donc tout l'écran (origine 0,0) pour que position de la
/// cible, position du regard et samples partagent le même repère.
///
/// **Orientation** : les samples sont liés à l'orientation de l'interface où ils ont été
/// pris. Calibrer dans une autre orientation repart de zéro ; tant que ça n'est pas fait,
/// `samplesCount` vaut 0 et `apply` renvoie le point brut.
///
/// **Capture d'un sample** : moyenne mobile exponentielle des features (≈ 150 ms), pour ne
/// pas enregistrer le bruit image par image.
@Observable
final class GazeCalibrator {
    static let shared = GazeCalibrator()

    static let featureCount = 4
    static let minimumSamples = 9

    private static let lambdaPerSample = 0.05
    private static let emaAlpha = 0.10

    struct Sample: Codable, Equatable {
        let features: [Double]
        /// Position visée, normalisée dans la fenêtre : [0, 1] × [0, 1].
        let target: [Double]
        /// Pris pendant une partie sur un dwell réussi : la cible était déjà là où le modèle
        /// pointait, donc ce sample ne mesure pas l'erreur réelle (voir `makeReport`).
        var selfLabelled = false
    }

    /// Qualité de l'ajustement, en pixels : erreur RMS en validation croisée leave-one-out
    /// (l'erreur sur un point que le modèle n'a pas vu) et part de variance expliquée.
    /// `sampleCount` = samples retenus après rejet des taps aberrants.
    struct FitReport: Equatable {
        var sampleCount = 0
        var looX = 0.0, looY = 0.0
        var looR2X = 0.0, looR2Y = 0.0
        var typicalError: Double { (looX * looX + looY * looY).squareRoot() }
    }

    private struct Store: Codable {
        var orientation: Int
        var samples: [Sample]
    }

    private var samples: [Sample] = []
    private var sampleOrientation = 0
    private let maxSamples: Int
    private let persistenceKey = "afsr.eyegame.calibration.v6"

    private(set) var isTrained = false
    private(set) var report = FitReport()

    // Chemin chaud (60 Hz) : jamais lu par une vue, donc exclu de l'observation.
    @ObservationIgnored private var model: GazeRidgeModel?
    @ObservationIgnored private var latestFeatures = [Double](repeating: 0, count: GazeCalibrator.featureCount)
    @ObservationIgnored private var emaFeatures = [Double](repeating: 0, count: GazeCalibrator.featureCount)
    @ObservationIgnored private var emaReady = false
    @ObservationIgnored private var canvasSize = UIScreen.main.bounds.size
    @ObservationIgnored private var currentOrientation = GazeCalibrator.interfaceOrientation()
    @ObservationIgnored private var samplesSinceReport = 0

    init(maxSamples: Int = 200) {
        self.maxSamples = maxSamples
        load()
        refit()
    }

    // MARK: - État

    /// Samples valables pour l'orientation actuelle de l'interface.
    var samplesCount: Int {
        let count = samples.count
        return sampleOrientation == Self.interfaceOrientation() ? count : 0
    }

    /// Rayon de dwell conseillé : plus la calibration est imprécise, plus on accepte large.
    /// 1,3 × l'erreur typique couvre environ 80 % des mesures autour d'une fixation.
    var recommendedDwellRadius: CGFloat {
        max(80, min(220, CGFloat(report.typicalError) * 1.3))
    }

    static func interfaceOrientation() -> Int {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return (scene?.interfaceOrientation ?? .portrait).rawValue
    }

    // MARK: - Features (60 Hz)

    func updateFeatures(_ features: [Double], canvasSize: CGSize, orientation: Int) {
        guard features.count == Self.featureCount, canvasSize.width > 1, canvasSize.height > 1 else { return }
        latestFeatures = features
        self.canvasSize = canvasSize
        currentOrientation = orientation
        if emaReady {
            for i in 0..<features.count {
                emaFeatures[i] += Self.emaAlpha * (features[i] - emaFeatures[i])
            }
        } else {
            emaFeatures = features
            emaReady = true
        }
    }

    /// À appeler quand la cible change : la moyenne repart de la mesure courante, sans
    /// l'historique de la cible précédente. Reste prête à enregistrer immédiatement.
    func resetEMA() {
        if emaReady { emaFeatures = latestFeatures }
    }

    /// Règle le filtre de Kalman d'un jeu sur la qualité réelle de la calibration : le bruit de
    /// mesure supposé suit l'erreur mesurée (au moins 8 px), pas seulement le nombre de samples.
    func tune(_ kalman: GazeKalmanFilter) {
        kalman.setCalibrationConfidence(sampleCount: samplesCount)
        kalman.measurementSigmaFloor = max(8, report.typicalError * 0.5)
    }

    // MARK: - Inférence

    /// Position prédite dans la fenêtre. `raw` n'est qu'un repli tant qu'aucun modèle n'est
    /// entraîné pour l'orientation courante.
    func apply(_ raw: CGPoint) -> CGPoint {
        guard let model, currentOrientation == sampleOrientation else { return raw }
        let p = model.predict(latestFeatures)
        return CGPoint(x: min(max(p[0], -0.1), 1.1) * canvasSize.width,
                       y: min(max(p[1], -0.1), 1.1) * canvasSize.height)
    }

    // MARK: - Calibration

    /// Enregistre `(features lissées, position de la cible)`. `target` est en coordonnées de
    /// fenêtre. Retourne false si ARKit n'a pas encore fourni de mesure.
    @discardableResult
    func addSample(target: CGPoint, selfLabelled: Bool = false) -> Bool {
        guard emaReady else { return false }
        if sampleOrientation != currentOrientation {
            samples.removeAll()
            sampleOrientation = currentOrientation
        }
        samples.append(Sample(
            features: emaFeatures,
            target: [Double(target.x / canvasSize.width), Double(target.y / canvasSize.height)],
            selfLabelled: selfLabelled
        ))
        // Au-delà du plafond on évince d'abord les samples auto-étiquetés : la calibration
        // guidée ne doit pas disparaître au profit de samples de jeu.
        while samples.count > maxSamples {
            if let i = samples.firstIndex(where: { $0.selfLabelled }) {
                samples.remove(at: i)
            } else {
                samples.removeFirst()
            }
        }
        samplesSinceReport += 1
        refit()
        save()
        return true
    }

    func reset() {
        samples.removeAll()
        model = nil
        isTrained = false
        report = FitReport()
        save()
    }

    // MARK: - Ajustement

    private func refit() {
        guard samples.count >= Self.minimumSamples else {
            clearModel()
            return
        }
        let w = Double(canvasSize.width)
        let h = Double(canvasSize.height)
        let all = samples.map { (x: $0.features, y: $0.target) }

        guard var fitted = GazeRidgeModel.fit(samples: all, lambda: Self.lambdaPerSample * Double(all.count)) else {
            clearModel()
            return
        }
        var used = all

        // Passe robuste : un tap pris alors que l'enfant regardait ailleurs fausserait tout
        // le modèle. On écarte les points très au-delà de l'erreur médiane et on réajuste.
        let residuals = all.map { s -> Double in
            let p = fitted.predict(s.x)
            return hypot((p[0] - s.y[0]) * w, (p[1] - s.y[1]) * h)
        }
        let median = residuals.sorted()[residuals.count / 2]
        let threshold = max(3 * median, 120)
        let keep = residuals.indices.filter { residuals[$0] <= threshold }
        var usedIndices = Array(all.indices)
        if keep.count < all.count,
           keep.count >= max(Self.minimumSamples, Int(Double(all.count) * 0.6)),
           let refitted = GazeRidgeModel.fit(samples: keep.map { all[$0] },
                                             lambda: Self.lambdaPerSample * Double(keep.count)) {
            fitted = refitted
            usedIndices = keep
        }

        model = fitted
        isTrained = true

        // Le rapport (24 ajustements) n'est recalculé à chaque sample que tant qu'il y en a peu ;
        // ensuite tous les 10 samples, pour ne pas ralentir la partie.
        guard samples.count <= 40 || samplesSinceReport >= 10 || report.sampleCount == 0 else { return }
        samplesSinceReport = 0
        used = usedIndices.map { all[$0] }
        let measured = usedIndices.indices.filter { !samples[usedIndices[$0]].selfLabelled }
        report = Self.makeReport(data: used, evaluate: measured, width: w, height: h)
    }

    private func clearModel() {
        model = nil
        isTrained = false
        report = FitReport()
    }

    /// `evaluate` : positions dans `data` des samples sur lesquels mesurer l'erreur. Les samples
    /// auto-étiquetés sont exclus (ils sont consistants avec le modèle par construction).
    private static func makeReport(data: [(x: [Double], y: [Double])], evaluate: [Int],
                                   width w: Double, height h: Double) -> FitReport {
        var r = FitReport()
        r.sampleCount = data.count
        let n = Double(data.count)

        // Leave-one-out sur les 24 samples les plus récents : un ajustement par sample, ce
        // qui reste imperceptible même dans un build Debug.
        var lx = 0.0, ly = 0.0, count = 0.0
        for i in (evaluate.isEmpty ? Array(data.indices) : evaluate).suffix(24) {
            var train = data
            train.remove(at: i)
            guard let m = GazeRidgeModel.fit(samples: train, lambda: lambdaPerSample * Double(train.count)) else { continue }
            let p = m.predict(data[i].x)
            lx += pow((p[0] - data[i].y[0]) * w, 2)
            ly += pow((p[1] - data[i].y[1]) * h, 2)
            count += 1
        }
        guard count > 0 else { return r }
        r.looX = (lx / count).squareRoot()
        r.looY = (ly / count).squareRoot()

        let meanX = data.reduce(0.0) { $0 + $1.y[0] * w } / n
        let meanY = data.reduce(0.0) { $0 + $1.y[1] * h } / n
        let varX = data.reduce(0.0) { $0 + pow($1.y[0] * w - meanX, 2) } / n
        let varY = data.reduce(0.0) { $0 + pow($1.y[1] * h - meanY, 2) } / n
        if varX > 1 { r.looR2X = 1 - (r.looX * r.looX) / varX }
        if varY > 1 { r.looR2Y = 1 - (r.looY * r.looY) / varY }
        return r
    }

    // MARK: - Persistance

    private func save() {
        let store = Store(orientation: sampleOrientation, samples: samples)
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else { return }
        sampleOrientation = store.orientation
        // Les erreurs en pixels de `refit()` doivent utiliser la fenêtre de l'orientation d'origine.
        let screen = UIScreen.main.bounds.size
        let landscape = store.orientation == UIInterfaceOrientation.landscapeLeft.rawValue
            || store.orientation == UIInterfaceOrientation.landscapeRight.rawValue
        canvasSize = landscape
            ? CGSize(width: max(screen.width, screen.height), height: min(screen.width, screen.height))
            : CGSize(width: min(screen.width, screen.height), height: max(screen.width, screen.height))
        samples = store.samples.filter { $0.features.count == Self.featureCount && $0.target.count == 2 }
        if samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
    }
}
