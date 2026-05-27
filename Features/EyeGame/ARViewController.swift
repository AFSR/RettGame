import SwiftUI
import ARKit
import simd
import os.log

/// Wrapper UIKit pour le suivi du regard.
///
/// **Approche V5 — `lookAtPoint` + lancer de rayon par œil**
///
/// Découverte sur V4 : les matrices `leftEyeTransform` / `rightEyeTransform`
/// d'ARKit n'encodent **pas la rotation du regard**, seulement la position
/// 3D des globes oculaires dans le visage avec une orientation alignée sur
/// le visage. Extraire le "forward" via `-columns.2` donnait donc toujours
/// la même direction (vers l'avant du visage) quelle que soit la direction
/// du regard. La pipeline V4 ne réagissait qu'à la position des yeux (=
/// mouvements de tête), pas au regard. Symptôme observé : le point ne
/// bougeait qu'en vertical (les yeux montent/descendent dans le visage
/// quand la tête bouge) et restait collé horizontalement (les positions
/// gauche/droite des deux yeux se moyennent à 0 quels que soient leurs
/// rotations individuelles).
///
/// Apple expose donc séparément **`face.lookAtPoint`** : un point 3D, en
/// repère face-local, où les deux axes oculaires convergent. C'est lui qui
/// contient l'info de rotation du regard. On reconstruit donc un rayon
/// par œil = `(position de l'œil, direction vers lookAtPoint)` et on
/// intersecte chacun avec le plan de l'écran. Moyenne binoculaire pour
/// la robustesse.
///
/// **Différence avec la V1 "lookAtPoint" qui avait été abandonnée** :
/// l'ancienne tentative passait par `ARSCNView.projectPoint` (projection
/// caméra perspective), qui compresse vers le centre quand le point est
/// proche du device. Ici on fait une intersection rayon-plan explicite,
/// pas de problème de compression.
final class ARFaceViewController: UIViewController, ARSessionDelegate {

    private static let log = Logger(subsystem: "fr.afsr.RettApp", category: "EyeGame.AR")

    let arSession = ARSession()
    var onGazeUpdate: ((CGPoint) -> Void)?
    /// Callback diagnostic : `(h, v)` sont l'angle du regard en degrés.
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

        // Transformation face-local → device-local (= caméra-local).
        // Combine la pose de la tête + le déplacement éventuel du device,
        // pour que le plan z = 0 corresponde toujours à l'écran.
        let faceToDevice = cameraTransform.inverse * face.transform

        // Positions des yeux et point de convergence en repère face. C'est
        // `lookAtPoint` qui porte l'info de rotation du regard ; les eye
        // transforms ne donnent que la position des globes.
        let leftEyePosFace  = simd_make_float3(face.leftEyeTransform.columns.3)
        let rightEyePosFace = simd_make_float3(face.rightEyeTransform.columns.3)
        let lookAtFace      = face.lookAtPoint

        // Direction de regard pour chaque œil = (œil → convergence) en repère
        // face, puis transportée en repère device. Le w = 0 traite ces vecteurs
        // comme des directions (pas affectés par la translation).
        let leftDirFace  = simd_normalize(lookAtFace - leftEyePosFace)
        let rightDirFace = simd_normalize(lookAtFace - rightEyePosFace)
        let leftDir  = simd_make_float3(faceToDevice * simd_float4(leftDirFace,  0))
        let rightDir = simd_make_float3(faceToDevice * simd_float4(rightDirFace, 0))

        // Positions des yeux en repère device.
        let leftPos  = simd_make_float3((faceToDevice * face.leftEyeTransform).columns.3)
        let rightPos = simd_make_float3((faceToDevice * face.rightEyeTransform).columns.3)

        guard let leftHit  = intersectScreenPlane(origin: leftPos,  direction: leftDir),
              let rightHit = intersectScreenPlane(origin: rightPos, direction: rightDir)
        else { return }

        let avgHit = (leftHit + rightHit) * 0.5

        // Conversion mètres (repère caméra) → pixels logiques (repère UI).
        // - Caméra à l'origine, +Y vers le haut du device, +X vers la droite.
        // - Écran : x ∈ [-w/2, +w/2], y ∈ [-h, 0]. En portrait la caméra est
        //   au-dessus de l'écran donc y=0 = haut, y<0 = bas.
        // - Repère UI : (0, 0) en haut-gauche, x → droite, y → bas.
        let bounds = UIScreen.main.bounds
        let screenX = bounds.width * 0.5 + CGFloat(avgHit.x * pixelsPerMeter)
        let screenY = CGFloat(-avgHit.y * pixelsPerMeter)
        let screenPoint = CGPoint(x: screenX, y: screenY)

        // Angles diagnostic : direction moyenne du regard, projetée en h, v.
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

    /// Intersection d'un rayon `(origin, direction)` avec le plan z = 0
    /// dans le repère local du device (= la surface de l'écran).
    @inline(__always)
    private func intersectScreenPlane(origin: simd_float3,
                                      direction: simd_float3) -> simd_float2? {
        guard direction.z < -0.01 else { return nil }
        let t = -origin.z / direction.z
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
