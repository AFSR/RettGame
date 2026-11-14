import Foundation
import Vision
import CoreGraphics
import CoreVideo
import QuartzCore
import os.log

/// Cache thread-safe des offsets de pupille extraits par Vision.
///
/// À chaque frame ARKit on peut soumettre le `CVPixelBuffer` de la caméra via
/// `submit(pixelBuffer:)`. Une requête `VNDetectFaceLandmarksRequest` (65-point
/// constellation, qui inclut les sous-features `leftPupil`/`rightPupil`) tourne
/// en arrière-plan. Si une inférence précédente est encore en cours, on saute
/// la frame — ce qui throttle naturellement à ~20–30 Hz sur iPhone récent, un
/// peu moins sur iPad Air M3, largement suffisant pour nourrir un signal de
/// regard lissé derrière.
///
/// Le résultat exposé est `latestPupilOffset`, un `CGPoint` dans [-0.5, +0.5]
/// environ : l'offset 2D du centre de la pupille par rapport au centre de l'œil,
/// normalisé par la largeur de l'œil (invariant à la distance). La convention
/// `X > 0 = regard à droite` dépend de l'orientation du pixel buffer ; en
/// `.leftMirrored` (ce qu'on utilise pour la TrueDepth frontale en portrait),
/// le repère Vision est déjà aligné sur la perspective de l'utilisateur,
/// donc `X > 0` = utilisateur regarde à sa droite (anatomiquement).
final class GazePupilTracker {

    private static let log = Logger(subsystem: "fr.afsr.RettApp", category: "EyeGame.PupilTracker")

    private let queue = DispatchQueue(label: "fr.afsr.gaze.vision", qos: .userInteractive)
    private let sequenceHandler = VNSequenceRequestHandler()
    private let lock = NSLock()
    private var isProcessing = false

    private var _latestPupilOffset: CGPoint = .zero
    private var _hasPupilData = false
    private var _lastUpdateTime: CFTimeInterval = 0

    /// Dernier offset moyen gauche/droit disponible. `.zero` si aucune frame
    /// n'a encore produit de résultat.
    var latestPupilOffset: CGPoint {
        lock.lock(); defer { lock.unlock() }
        return _latestPupilOffset
    }

    /// `true` dès qu'au moins une inférence Vision a donné un résultat
    /// exploitable.
    var hasPupilData: Bool {
        lock.lock(); defer { lock.unlock() }
        return _hasPupilData
    }

    /// Timestamp (`CACurrentMediaTime`) du dernier update. Utile pour détecter
    /// un signal Vision stale (visage perdu, inférence trop lente).
    var lastUpdateTime: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _lastUpdateTime
    }

    /// Soumet un pixel buffer pour inférence. Thread-safe. Si une inférence
    /// précédente est encore en vol, la frame est silencieusement ignorée.
    func submit(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        if isProcessing {
            lock.unlock()
            return
        }
        isProcessing = true
        lock.unlock()

        // Vision est thread-safe sur un sequence handler dédié ; on retient
        // le pixel buffer (ARKit le libère sinon dès qu'on sort du
        // didUpdate), sous forme opaque — le ref count s'en charge.
        queue.async { [weak self] in
            self?.process(pixelBuffer: pixelBuffer)
            self?.lock.lock()
            self?.isProcessing = false
            self?.lock.unlock()
        }
    }

    private func process(pixelBuffer: CVPixelBuffer) {
        let request = VNDetectFaceLandmarksRequest()
        request.constellation = .constellation65Points

        do {
            // TrueDepth frontale en portrait : le buffer est dans
            // l'orientation native du capteur (landscape). `.leftMirrored`
            // donne à Vision l'image redressée du point de vue utilisateur.
            try sequenceHandler.perform([request],
                                        on: pixelBuffer,
                                        orientation: .leftMirrored)
        } catch {
            Self.log.error("VNDetectFaceLandmarksRequest failed: \(error.localizedDescription)")
            return
        }

        guard let face = request.results?.first,
              let lm = face.landmarks,
              let leftEye = lm.leftEye,
              let rightEye = lm.rightEye,
              let leftPupil = lm.leftPupil,
              let rightPupil = lm.rightPupil,
              let leftOffset  = pupilOffset(eye: leftEye,  pupil: leftPupil),
              let rightOffset = pupilOffset(eye: rightEye, pupil: rightPupil)
        else { return }

        let avg = CGPoint(
            x: (leftOffset.x + rightOffset.x) * 0.5,
            y: (leftOffset.y + rightOffset.y) * 0.5
        )

        lock.lock()
        _latestPupilOffset = avg
        _hasPupilData = true
        _lastUpdateTime = CACurrentMediaTime()
        lock.unlock()
    }

    /// Offset 2D de la pupille par rapport au centre géométrique de l'œil,
    /// normalisé par la largeur de l'œil (distance du coin externe au coin
    /// interne). L'invariance à la distance vient de cette normalisation.
    private func pupilOffset(eye: VNFaceLandmarkRegion2D,
                             pupil: VNFaceLandmarkRegion2D) -> CGPoint? {
        let eyePoints = eye.normalizedPoints
        guard eyePoints.count >= 4, pupil.normalizedPoints.count >= 1 else { return nil }

        // Centre de l'œil = moyenne arithmétique des points d'outline.
        var sumX: CGFloat = 0, sumY: CGFloat = 0
        for p in eyePoints { sumX += p.x; sumY += p.y }
        let n = CGFloat(eyePoints.count)
        let eyeCx = sumX / n
        let eyeCy = sumY / n

        // Largeur de l'œil approchée par la distance entre coin externe
        // (index 0 typique) et coin interne (milieu de l'outline).
        let a = eyePoints[0]
        let b = eyePoints[eyePoints.count / 2]
        let eyeWidth = hypot(b.x - a.x, b.y - a.y)
        guard eyeWidth > 0.001 else { return nil }

        let pc = pupil.normalizedPoints[0]
        return CGPoint(
            x: (pc.x - eyeCx) / eyeWidth,
            y: (pc.y - eyeCy) / eyeWidth
        )
    }
}
