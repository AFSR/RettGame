import SwiftUI
import ARKit
import simd
import os.log

/// Wrapper UIKit pour le suivi du regard.
///
/// **Approche V4 — lancer de rayon depuis les eye transforms 3D**
///
/// On utilise directement `face.leftEyeTransform` et `face.rightEyeTransform`
/// que ARKit expose comme matrices 4×4 — c'est-à-dire la position et
/// l'orientation 3D de chaque œil dans le repère du visage. Combinées avec
/// `face.transform` (pose du visage dans le repère monde), on obtient les
/// poses des yeux en monde.
///
/// Pour chaque œil on calcule un rayon `(origine = position de l'œil,
/// direction = forward de l'œil = -Z local)`. On intersecte ce rayon avec
/// le **plan de l'écran** (z = 0 en repère monde pour
/// `ARFaceTrackingConfiguration`, qui place l'origine monde à la caméra et
/// +Z vers l'utilisateur). On moyenne les deux intersections (œil gauche +
/// œil droit) et on convertit des mètres en pixels logiques.
///
/// **Pourquoi pas les blendShapes ?** Les `eyeLookOut/In/Up/Down*` sont des
/// valeurs ∈ [0, 1] quantifiées, destinées à l'animation faciale (Memoji),
/// pas au suivi de regard précis. Elles saturent, ont une dynamique
/// asymétrique, et sont une projection grossière. La littérature
/// (TabletGaze, comparatifs ARKit/Tobii) recommande les eye transforms.
///
/// **Pourquoi pas `lookAtPoint` ?** C'est le point de **convergence** des
/// deux axes oculaires (où les yeux se croisent). À 30 cm de l'écran les
/// yeux sont quasi parallèles → la convergence est numériquement instable
/// (très sensible au bruit d'orientation). Le lancer de rayon par œil puis
/// moyenne est plus stable.
///
/// **Avantage clé** : la calibration devient un fine-tuning d'un signal
/// déjà géométriquement correct (au lieu d'avoir à inventer toute la
/// transformation comme avec les blendShapes). Et le mouvement de tête est
/// naturellement compensé puisqu'on travaille en repère monde.
final class ARFaceViewController: UIViewController, ARSessionDelegate {

    private static let log = Logger(subsystem: "fr.afsr.RettApp", category: "EyeGame.AR")

    let arSession = ARSession()
    var onGazeUpdate: ((CGPoint) -> Void)?
    /// Callback diagnostic : `(h, v)` sont l'angle du regard en degrés
    /// (h = composante horizontale, v = verticale). Range typique ±20°.
    var onGazeDiagnostic: ((_ h: CGFloat, _ v: CGFloat) -> Void)?

    /// Conversion mètres → pixels logiques. Calibré sur iPhone 14 (844 pts
    /// de haut pour ~146.7 mm de hauteur d'écran ≈ 5752 pts/m). Les autres
    /// modèles sont dans ±10 % de cette valeur ; le calibrateur compense.
    private let pixelsPerMeter: Float = 5750

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

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked,
              let cameraTransform = session.currentFrame?.camera.transform
        else { return }

        // Poses des yeux en repère **caméra/device** (pas monde). On
        // transforme tout dans le repère local du device pour que le plan
        // de l'écran soit toujours z = 0 quoi que le device fasse — sinon
        // un léger déplacement du device tordrait toute la projection.
        let cameraInverse = cameraTransform.inverse
        let leftEye  = cameraInverse * face.transform * face.leftEyeTransform
        let rightEye = cameraInverse * face.transform * face.rightEyeTransform

        // Position de chaque œil dans le repère caméra (en mètres).
        let leftPos  = simd_make_float3(leftEye.columns.3)
        let rightPos = simd_make_float3(rightEye.columns.3)

        // Direction du regard pour chaque œil. Convention ARKit : le +Z
        // local d'un eyeTransform sort "à l'arrière du globe oculaire", le
        // regard part donc dans la direction **-Z** local.
        let leftDir  = -simd_make_float3(leftEye.columns.2)
        let rightDir = -simd_make_float3(rightEye.columns.2)

        guard let leftHit  = intersectScreenPlane(origin: leftPos,  direction: leftDir),
              let rightHit = intersectScreenPlane(origin: rightPos, direction: rightDir)
        else { return }

        // Moyenne binoculaire — plus robuste qu'un œil seul.
        let avgHit = (leftHit + rightHit) * 0.5

        // Conversion mètres (repère caméra) → pixels logiques (repère UI).
        // - Caméra à l'origine, +Y vers le haut du device, +X vers la droite.
        // - Écran : x ∈ [-w/2, +w/2], y ∈ [-h, 0] (l'écran s'étend du
        //   bord caméra vers le bas du device). En portrait, la caméra est
        //   au-dessus de l'écran donc y=0 = haut, y<0 = bas.
        // - Repère UI : (0, 0) en haut-gauche, x → droite, y → bas.
        let bounds = UIScreen.main.bounds
        let screenX = bounds.width * 0.5 + CGFloat(avgHit.x * pixelsPerMeter)
        let screenY = CGFloat(-avgHit.y * pixelsPerMeter)
        let screenPoint = CGPoint(x: screenX, y: screenY)

        // Angles diagnostic (en degrés) à partir de la direction moyenne.
        // h = atan(x / |z|), v = atan(y / |z|).
        let avgDir = simd_normalize((leftDir + rightDir) * 0.5)
        let absZ = max(0.001, abs(avgDir.z))
        let hDeg = CGFloat(atan2(avgDir.x, absZ) * 180 / .pi)
        let vDeg = CGFloat(atan2(avgDir.y, absZ) * 180 / .pi)

        let now = CACurrentMediaTime()
        if now - lastLogTime > 2.0 {
            lastLogTime = now
            Self.log.info(
                "gaze hit=\(avgHit.x, format: .fixed(precision: 3)),\(avgHit.y, format: .fixed(precision: 3))m angle=\(hDeg, format: .fixed(precision: 1)),\(vDeg, format: .fixed(precision: 1))° → screen \(Int(screenX))/\(Int(screenY))"
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.onGazeUpdate?(screenPoint)
            self?.onGazeDiagnostic?(hDeg, vDeg)
        }
    }

    /// Intersection d'un rayon `(origin, direction)` avec le plan `z = 0`
    /// dans le repère local du device. Le plan z = 0 correspond à la
    /// surface de l'écran (la caméra et l'écran sont essentiellement
    /// coplanaires sur un iPhone).
    ///
    /// Retourne `nil` si le rayon est parallèle au plan ou s'il pointe
    /// dans la mauvaise direction (l'utilisateur regarde en arrière).
    @inline(__always)
    private func intersectScreenPlane(origin: simd_float3,
                                      direction: simd_float3) -> simd_float2? {
        // L'œil est devant la caméra → origin.z > 0. Pour que le rayon
        // atteigne l'écran (z = 0), direction.z doit être négative.
        guard direction.z < -0.01 else { return nil }
        let t = -origin.z / direction.z  // > 0 par construction
        let hit = origin + t * direction
        return simd_float2(hit.x, hit.y)
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
