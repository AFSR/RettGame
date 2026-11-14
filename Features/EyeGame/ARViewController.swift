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

        // --- 1) Pipeline ARKit (V7.1 — ray-cast depuis le visage à travers
        //        lookAtPoint, intersecté avec le plan écran) ---
        //
        // Au lieu de projeter directement `lookAtPoint` (ce qui sous-estime la
        // course du regard quand ARKit rapporte un point proche du visage),
        // on trace un rayon depuis la position du visage dans la direction de
        // lookAtPoint et on intersecte avec z = 0 (plan de l'écran en repère
        // caméra). Ça extrapole correctement : pour un petit déplacement
        // oculaire mesuré, le rayon atteint quand même la périphérie de
        // l'écran si c'est là que le regard pointe réellement.
        let facePosCam = simd_mul(cameraTransform.inverse, face.transform.columns.3)
        let faceOrigin = simd_make_float3(facePosCam)

        let lookAtWorld = face.transform * simd_float4(face.lookAtPoint, 1)
        let lookAtCam4 = simd_mul(simd_inverse(cameraTransform), lookAtWorld)
        let lookAtCam = simd_make_float3(lookAtCam4)

        let gazeDirection = lookAtCam - faceOrigin
        // Le plan écran est z = 0, le visage est devant la caméra (z > 0).
        // Pour que le rayon atteigne l'écran, direction.z doit être négative.
        // Si direction.z ≈ 0 (parallèle au plan), on retombe sur la projection
        // directe pour éviter un hit à l'infini.
        let hitXY: SIMD2<Float>
        if gazeDirection.z < -0.01 {
            let t = -faceOrigin.z / gazeDirection.z
            let hit = faceOrigin + t * gazeDirection
            hitXY = SIMD2(hit.x, hit.y)
        } else {
            // Fallback : projection directe de lookAtPoint.
            hitXY = SIMD2(lookAtCam.x, lookAtCam.y)
        }

        let bounds = UIScreen.main.bounds
        // Amplification empirique : ARKit sous-rapporte souvent la course du
        // regard (les yeux bougent peu physiquement même pour grand angle de
        // regard). Un facteur 1.8 étire la plage typique (±40 % d'écran) pour
        // atteindre les bords. La calibration en aval compense si c'est trop
        // ou pas assez.
        let amplification: Float = 1.8
        let normX = hitXY.y * amplification / (screen.widthM  * 0.5)
        let normY = hitXY.x * amplification / (screen.heightM * 0.5)
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

        // --- 3) Features MLP (calculées sync avant dispatch main) ---
        // Vecteur 9D consommé par le calibrateur `GazeMLP`. Inclut :
        //   [0,1] arkit normalisé sur la taille écran
        //   [2-4] vecteur +Z du repère visage en caméra-local (orientation
        //         de la tête compressée en 3 valeurs, invariante à l'ordre
        //         d'application des rotations)
        //   [5,6] offset pupillaire Vision (0 si pas encore de détection)
        //   [7,8] clignement gauche/droit depuis les blendShapes ARKit
        let headInCamera = cameraTransform.inverse * face.transform
        let headFwd = simd_make_float3(headInCamera.columns.2)
        let blends = face.blendShapes
        let leftBlink  = (blends[.eyeBlinkLeft]  as? NSNumber)?.doubleValue ?? 0
        let rightBlink = (blends[.eyeBlinkRight] as? NSNumber)?.doubleValue ?? 0

        let features: [Double] = [
            Double(screenX / bounds.width),
            Double(screenY / bounds.height),
            Double(headFwd.x),
            Double(headFwd.y),
            Double(headFwd.z),
            Double(pupilOffset.x),
            Double(pupilOffset.y),
            leftBlink,
            rightBlink,
        ]

        // Un seul dispatch main : updateFeatures d'ABORD (le MLP a besoin
        // des features fraîches), puis onGazeUpdate déclenche l'apply()
        // côté VM qui va consommer ces features.
        DispatchQueue.main.async { [weak self] in
            GazeCalibrator.shared.updateFeatures(features, canvasSize: bounds.size)
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
