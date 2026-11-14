import SwiftUI
import ARKit
import simd
import os.log

/// Wrapper UIKit pour le suivi du regard.
///
/// **Approche V8 — hybride ARKit + Vision**
///
/// La V7 (ARKit `lookAtPoint` + axis swap + conversion mètres→pixels) donne
/// un signal fonctionnel mais limité par le bruit intrinsèque d'ARKit
/// (~5–10 mm à 30 cm). Pour aller plus loin on ajoute en parallèle une
/// pipeline Vision : `VNDetectFaceLandmarksRequest` sur le pixel buffer de
/// la caméra ARKit, extraction de la position de la pupille relative au
/// centre de l'œil, normalisée par la largeur de l'œil.
///
/// L'output ARKit reste **primaire** pour l'instant (consommé par le jeu
/// via `onGazeUpdate`). L'output Vision est exposé via `onVisionGaze` pour
/// affichage côté diagnostic — on va comparer visuellement avant de basculer
/// Vision en primaire dans un commit ultérieur.
final class ARFaceViewController: UIViewController, ARSessionDelegate {

    private static let log = Logger(subsystem: "fr.afsr.RettApp", category: "EyeGame.AR")

    let arSession = ARSession()
    var onGazeUpdate: ((CGPoint) -> Void)?
    /// Callback diagnostic ARKit : position caméra-local en mètres sur chaque
    /// axe (long = X, court = Y, voir V7 pour le swap vers l'UI).
    var onGazeDiagnostic: ((_ camX: CGFloat, _ camY: CGFloat) -> Void)?
    /// Callback diagnostic Vision : point écran dérivé de la position de la
    /// pupille, offset pupillaire normalisé (x, y ∈ [-0.5, +0.5]), et un
    /// booléen `hasData` à faux tant qu'aucune inférence n'a produit de
    /// résultat exploitable.
    var onVisionGaze: ((_ screenPoint: CGPoint, _ pupilOffset: CGPoint, _ hasData: Bool) -> Void)?

    /// Conversion mètres → pixels logiques (V7, device-aware).
    private var screen: ScreenSpec {
        let bounds = UIScreen.main.bounds
        let pointsPerMeter: Float = UIDevice.current.userInterfaceIdiom == .pad ? 4760 : 5455
        return ScreenSpec(
            widthM:  Float(bounds.width)  / pointsPerMeter,
            heightM: Float(bounds.height) / pointsPerMeter
        )
    }

    private struct ScreenSpec {
        let widthM: Float
        let heightM: Float
    }

    /// Gain de conversion `pupilOffset → pixels écran`. À 30 cm de distance
    /// l'amplitude utile du regard correspond à un pupil offset de ~±0.2 sur
    /// chaque axe. On veut que ±0.2 couvre environ une demi-largeur d'écran.
    private var visionGain: CGFloat {
        let bounds = UIScreen.main.bounds
        return bounds.width / 0.4  // 0.2 offset × gain = width/2
    }

    private let pupilTracker = GazePupilTracker()

    private var lastLogTime: CFTimeInterval = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        arSession.delegate = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARFaceTrackingConfiguration.isSupported else { return }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
        if #available(iOS 13.0, *) {
            config.maximumNumberOfTrackedFaces = 1
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arSession.pause()
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked,
              let frame = session.currentFrame
        else { return }
        let cameraTransform = frame.camera.transform

        // --- 1) Pipeline ARKit (V7, inchangée) ---
        let faceToDevice = cameraTransform.inverse * face.transform
        let lookAtWorld = face.transform * simd_float4(face.lookAtPoint, 1)
        let lookAtCam = simd_mul(simd_inverse(cameraTransform), lookAtWorld)

        let bounds = UIScreen.main.bounds
        let normX = lookAtCam.y / (screen.widthM  * 0.5)
        let normY = lookAtCam.x / (screen.heightM * 0.5)
        let screenX = CGFloat(normX) * (bounds.width  * 0.5) + bounds.width * 0.5
        let screenY = CGFloat(normY) * (bounds.height * 0.5)
        let arkitPoint = CGPoint(x: screenX, y: screenY)

        // --- 2) Pipeline Vision (nouvelle) ---
        // Soumet le pixel buffer pour inférence landmarks en background. Lit
        // le dernier résultat disponible (peut dater d'une frame ou deux).
        pupilTracker.submit(pixelBuffer: frame.capturedImage)
        let pupilOffset = pupilTracker.latestPupilOffset
        let hasVision = pupilTracker.hasPupilData
        // Convention Vision en `.leftMirrored` : x+ = regard à droite
        // (anatomique), y+ = regard vers le haut. On mappe sur UI iOS
        // (y+ = bas) → inversion sur Y.
        let visionScreenX = bounds.width  * 0.5 + pupilOffset.x * visionGain
        let visionScreenY = bounds.height * 0.5 - pupilOffset.y * visionGain
        let visionPoint = CGPoint(x: visionScreenX, y: visionScreenY)

        let now = CACurrentMediaTime()
        if now - lastLogTime > 2.0 {
            lastLogTime = now
            Self.log.info(
                "arkit=(\(Int(screenX)),\(Int(screenY))) vision hasData=\(hasVision) pupil=(\(pupilOffset.x, format: .fixed(precision: 3)),\(pupilOffset.y, format: .fixed(precision: 3))) → (\(Int(visionScreenX)),\(Int(visionScreenY)))"
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.onGazeUpdate?(arkitPoint)
            self?.onGazeDiagnostic?(CGFloat(lookAtCam.x), CGFloat(lookAtCam.y))
            self?.onVisionGaze?(visionPoint, pupilOffset, hasVision)
        }
    }
}

/// Représentable SwiftUI pour le tracking facial.
struct ARFaceView: UIViewControllerRepresentable {
    let onGazeUpdate: (CGPoint) -> Void
    var onGazeDiagnostic: ((CGFloat, CGFloat) -> Void)? = nil
    var onVisionGaze: ((CGPoint, CGPoint, Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> ARFaceViewController {
        let vc = ARFaceViewController()
        vc.onGazeUpdate = onGazeUpdate
        vc.onGazeDiagnostic = onGazeDiagnostic
        vc.onVisionGaze = onVisionGaze
        return vc
    }

    func updateUIViewController(_ vc: ARFaceViewController, context: Context) {
        vc.onGazeUpdate = onGazeUpdate
        vc.onGazeDiagnostic = onGazeDiagnostic
        vc.onVisionGaze = onVisionGaze
    }
}
