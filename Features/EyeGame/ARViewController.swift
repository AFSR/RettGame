import SwiftUI
import ARKit
import simd
import os.log

/// Wrapper UIKit pour le suivi du regard.
///
/// **Approche V7 — formule éprouvée de AR-Eye-Tracker / EyeTrackKit**
///
/// Après revue de la bibliographie (Shiru99/AR-Eye-Tracker, ukitomato/EyeTrackKit,
/// albertkornas/ARGazeDetect, tous des projets ARKit eye-tracking en
/// production), le bug fondamental que je cherchais : **les axes du repère
/// caméra ARKit sont swappés par rapport à l'UI iOS en portrait**.
///
/// Le capteur de la caméra TrueDepth est physiquement monté en orientation
/// landscape dans le device. L'axe X intrinsèque de la caméra correspond
/// donc à la **longueur physique** du device = axe **vertical** de l'UI en
/// portrait. Symétriquement, l'axe Y caméra = axe horizontal UI. La V6 qui
/// faisait `screenX ← lookAtPoint.x` envoyait donc le signal horizontal du
/// regard sur l'axe vertical de l'écran — exactement le symptôme reporté.
///
/// **Algorithme** (3 étapes) :
/// 1. `lookAtPointInWorld = face.transform * lookAtPoint`
///    (face-local → monde, suit la position de la tête)
/// 2. `lookAtPointInCamera = cameraTransform.inverse * lookAtPointInWorld`
///    (monde → caméra-local, suit le device)
/// 3. Mapping axes-swap vers l'UI portrait :
///    - UI x (horizontal écran) ← caméra .y, mis à l'échelle sur la largeur
///    - UI y (vertical écran)   ← caméra .x, mis à l'échelle sur la hauteur
///
/// La caméra étant en haut de l'écran en portrait, `lookAtPoint = (0, 0)` en
/// caméra-local correspond à l'iOS (centre horizontal, 0 = bord supérieur).
/// On ajoute donc `width/2` sur X mais rien sur Y.
final class ARFaceViewController: UIViewController, ARSessionDelegate {

    private static let log = Logger(subsystem: "fr.afsr.RettApp", category: "EyeGame.AR")

    let arSession = ARSession()
    var onGazeUpdate: ((CGPoint) -> Void)?
    /// Diagnostic exposant `lookAtPoint` en repère **caméra** (mètres). Ce qui
    /// est consommé en aval pour produire le point écran. `lookAtX` correspond
    /// au long axe device (= UI vertical en portrait), `lookAtY` au court
    /// axe (= UI horizontal en portrait).
    var onGazeDiagnostic: ((_ camX: CGFloat, _ camY: CGFloat) -> Void)?

    /// Dimensions physiques de l'écran en mètres, par modèle. Valeurs reprises
    /// d'EyeTrackKit pour iPhone 11/11 Pro/iPad. À défaut, fallback iPhone 14.
    private struct ScreenSpec {
        let widthM: Float
        let heightM: Float
    }
    private var screen: ScreenSpec {
        // En portrait (taille pour les iPhones modernes ~ iPhone 14)
        ScreenSpec(widthM: 0.0715, heightM: 0.1467)
    }

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
              let cameraTransform = session.currentFrame?.camera.transform
        else { return }

        // 1) face-local → monde
        let lookAtWorld = face.transform * simd_float4(face.lookAtPoint, 1)
        // 2) monde → caméra-local
        let lookAtCam = simd_mul(simd_inverse(cameraTransform), lookAtWorld)

        // 3) Mapping vers les pixels écran avec swap X/Y.
        //    Le `lookAtCam.x` (long axe device) va sur l'axe **vertical** UI,
        //    le `lookAtCam.y` (court axe device) va sur l'axe **horizontal** UI.
        //    La normalisation `/ (size/2) * pixelSize` donne des points
        //    centrés autour de zéro (de -pixelSize/2 à +pixelSize/2).
        let bounds = UIScreen.main.bounds
        let halfW = Float(bounds.width)  // half-pixel-width est `bounds.width / 2`, mais on cale différemment
        let halfH = Float(bounds.height)

        let normX = lookAtCam.y / (screen.widthM  * 0.5)  // ∈ environ [-1, +1] aux bords
        let normY = lookAtCam.x / (screen.heightM * 0.5)

        // En UI : (0, 0) = top-left, x→ droite, y→ bas. Caméra en haut-centre.
        let screenX = CGFloat(normX) * CGFloat(halfW * 0.5) + bounds.width * 0.5
        let screenY = CGFloat(normY) * CGFloat(halfH * 0.5)
        let screenPoint = CGPoint(x: screenX, y: screenY)

        let now = CACurrentMediaTime()
        if now - lastLogTime > 2.0 {
            lastLogTime = now
            Self.log.info(
                "lookAt cam=(\(lookAtCam.x, format: .fixed(precision: 4)),\(lookAtCam.y, format: .fixed(precision: 4)),\(lookAtCam.z, format: .fixed(precision: 4))) m → screen \(Int(screenX))/\(Int(screenY))"
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.onGazeUpdate?(screenPoint)
            self?.onGazeDiagnostic?(CGFloat(lookAtCam.x), CGFloat(lookAtCam.y))
        }
    }
}

/// Représentable SwiftUI pour le tracking facial.
struct ARFaceView: UIViewControllerRepresentable {
    let onGazeUpdate: (CGPoint) -> Void
    var onGazeDiagnostic: ((CGFloat, CGFloat) -> Void)? = nil

    func makeUIViewController(context: Context) -> ARFaceViewController {
        let vc = ARFaceViewController()
        vc.onGazeUpdate = onGazeUpdate
        vc.onGazeDiagnostic = onGazeDiagnostic
        return vc
    }

    func updateUIViewController(_ vc: ARFaceViewController, context: Context) {
        vc.onGazeUpdate = onGazeUpdate
        vc.onGazeDiagnostic = onGazeDiagnostic
    }
}
