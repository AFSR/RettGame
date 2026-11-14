import SwiftUI
import QuartzCore
import ARKit
import simd
import os.log

/// Suivi du regard par ARKit (`ARFaceTrackingConfiguration`).
///
/// À chaque frame on extrait deux mesures indépendantes de la direction du regard :
///
/// 1. **Impact géométrique** : intersection avec le plan de l'écran (z = 0 dans le repère
///    caméra) du rayon allant du milieu des yeux au point de fixation `lookAtPoint`. La
///    formule `œil + t·direction`, `t = −œil.z / direction.z`, ne dépend d'aucune
///    convention de signe sur z : le même rayon donne le même impact que l'axe de la
///    caméra pointe vers l'avant ou vers l'arrière.
/// 2. **Indices blendShapes** : horizontal et vertical, combinaison des 8 coefficients
///    `eyeLook{In,Out,Up,Down}{Left,Right}`. Mesure d'angle propre à l'utilisateur,
///    indépendante de l'orientation de l'appareil.
///
/// Ces quatre valeurs partent telles quelles vers `GazeCalibrator`, dont la régression
/// apprend l'association avec la position à l'écran (axes, signes, gain, décalage).
/// L'estimation renvoyée par `onGazeUpdate` n'est qu'un repli avant calibration.
///
/// Pendant un clignement ARKit perd la pupille et ses sorties sautent : on ignore ces
/// images et on garde la dernière mesure valide.
final class ARFaceViewController: UIViewController, ARSessionDelegate {

    private static let log = Logger(subsystem: "fr.afsr.RettApp", category: "EyeGame.AR")

    let arSession = ARSession()

    /// Estimation géométrique seule, en coordonnées de fenêtre (repli avant calibration).
    var onGazeUpdate: ((CGPoint) -> Void)?
    /// Les quatre features brutes : [impact x (m), impact y (m), blend horizontal, blend vertical].
    var onFeatures: (([Double]) -> Void)?

    private var lastLogTime: CFTimeInterval = 0
    /// Images consécutives ignorées pour cause de clignement, et dernier impact valide.
    private var blinkFrames = 0
    private var lastValidHit: SIMD2<Float>?

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
        config.maximumNumberOfTrackedFaces = 1
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arSession.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked,
              let cameraTransform = session.currentFrame?.camera.transform
        else { return }

        func coefficient(_ key: ARFaceAnchor.BlendShapeLocation) -> Double {
            face.blendShapes[key]?.doubleValue ?? 0
        }

        // Un clignement dure ~6 à 24 images à 60 Hz. Au-delà, les paupières sont simplement
        // mi-closes (ptosis, plissement des yeux) : on ne bloque plus le suivi.
        if max(coefficient(.eyeBlinkLeft), coefficient(.eyeBlinkRight)) >= 0.5 {
            blinkFrames += 1
            if blinkFrames <= 24 { return }
        } else {
            blinkFrames = 0
        }

        // Repère visage → repère caméra.
        let faceToCamera = cameraTransform.inverse * face.transform
        let eyeMidFace = (simd_make_float3(face.leftEyeTransform.columns.3)
                        + simd_make_float3(face.rightEyeTransform.columns.3)) * 0.5
        let eye = simd_make_float3(faceToCamera * simd_float4(eyeMidFace, 1))
        let look = simd_make_float3(faceToCamera * simd_float4(face.lookAtPoint, 1))
        // Impact du rayon ; s'il est indéfini on garde le dernier valide plutôt que de basculer
        // sur la projection directe, qui n'a pas la même définition (saut de plusieurs cm).
        let rayHit = Self.screenPlaneHit(eye: eye, look: look)
        let hit = rayHit ?? lastValidHit ?? SIMD2<Float>(look.x, look.y)
        if let rayHit { lastValidHit = rayHit }

        let horizontal = ((coefficient(.eyeLookOutRight) + coefficient(.eyeLookInLeft))
                        - (coefficient(.eyeLookOutLeft) + coefficient(.eyeLookInRight))) * 0.5
        let vertical = ((coefficient(.eyeLookUpRight) + coefficient(.eyeLookUpLeft))
                      - (coefficient(.eyeLookDownRight) + coefficient(.eyeLookDownLeft))) * 0.5

        let features: [Double] = [Double(hit.x), Double(hit.y), horizontal, vertical]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let bounds = self.view.window?.bounds ?? UIScreen.main.bounds
            let orientation = self.view.window?.windowScene?.interfaceOrientation.rawValue
                ?? UIInterfaceOrientation.portrait.rawValue

            // D'abord les features (le calibrateur les lit dans `apply`), ensuite le callback.
            GazeCalibrator.shared.updateFeatures(features, canvasSize: bounds.size, orientation: orientation)

            // Repli géométrique, valable en portrait (l'axe long de la caméra est l'axe
            // vertical de l'écran) : 1 m ≈ 5455 pt sur iPhone, 4760 pt sur iPad.
            let pointsPerMeter: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 4760 : 5455
            let gain = pointsPerMeter * 1.8
            let fallback = CGPoint(x: bounds.width * 0.5 + CGFloat(hit.y) * gain,
                                   y: CGFloat(hit.x) * gain)

            self.onGazeUpdate?(fallback)
            self.onFeatures?(features)

            let now = CACurrentMediaTime()
            if now - self.lastLogTime > 2.0 {
                self.lastLogTime = now
                Self.log.info(
                    "gaze hit=(\(hit.x, format: .fixed(precision: 4)),\(hit.y, format: .fixed(precision: 4)))m blend=(\(horizontal, format: .fixed(precision: 3)),\(vertical, format: .fixed(precision: 3))) orientation=\(orientation)"
                )
            }
        }
    }

    /// Impact du rayon œil → point de fixation sur le plan z = 0 (repère caméra).
    /// nil si le rayon est quasi parallèle à l'écran ou ne le rencontre pas devant lui.
    private static func screenPlaneHit(eye: SIMD3<Float>, look: SIMD3<Float>) -> SIMD2<Float>? {
        let direction = look - eye
        if abs(direction.z) > 0.02 {
            let t = -eye.z / direction.z
            if t > 0.2 && t < 8 {
                return SIMD2<Float>(eye.x + t * direction.x, eye.y + t * direction.y)
            }
        }
        return nil
    }
}

/// Représentable SwiftUI pour le suivi du regard.
struct ARFaceView: UIViewControllerRepresentable {
    let onGazeUpdate: (CGPoint) -> Void
    var onFeatures: (([Double]) -> Void)? = nil

    func makeUIViewController(context: Context) -> ARFaceViewController {
        let vc = ARFaceViewController()
        vc.onGazeUpdate = onGazeUpdate
        vc.onFeatures = onFeatures
        return vc
    }

    func updateUIViewController(_ vc: ARFaceViewController, context: Context) {
        vc.onGazeUpdate = onGazeUpdate
        vc.onFeatures = onFeatures
    }
}
