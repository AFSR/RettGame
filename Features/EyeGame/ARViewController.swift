import SwiftUI
import ARKit
import simd
import os.log

/// Wrapper UIKit pour le suivi du regard.
///
/// **Approche V6 — `lookAtPoint` direct, zéro transformation**
///
/// Après itérations sur ray-cast / matrices / blendShapes, on simplifie au
/// maximum pour pouvoir diagnostiquer. On expose à la couche supérieure
/// les valeurs brutes de `face.lookAtPoint` (en face-local, donc en
/// mètres dans le repère du visage). Le mapping écran utilise
/// directement `lookAtPoint.x` et `.y` avec un scale linéaire — pas de
/// transformations qui pourraient masquer un signal absent.
///
/// Si à l'utilisation la pipeline ne réagit pas dans une dimension, c'est
/// que `lookAtPoint` lui-même ne porte pas le signal sur cette dimension
/// (côté ARKit). Cas auquel il faudra revenir aux blendShapes ou à une
/// approche ML.
final class ARFaceViewController: UIViewController, ARSessionDelegate {

    private static let log = Logger(subsystem: "fr.afsr.RettApp", category: "EyeGame.AR")

    let arSession = ARSession()
    var onGazeUpdate: ((CGPoint) -> Void)?
    /// Diagnostic exposant les **valeurs brutes** de `face.lookAtPoint` en
    /// mètres dans le repère du visage. Permet à l'UI de montrer ce
    /// qu'ARKit envoie avant tout traitement.
    var onGazeDiagnostic: ((_ lookAtX: CGFloat, _ lookAtY: CGFloat) -> Void)?

    /// Conversion mètres face-local → pixels logiques. Pour un utilisateur
    /// à ~30 cm devant l'iPhone, l'amplitude horizontale du regard sur les
    /// bords d'écran correspond à `lookAtPoint.x ≈ ±0.04 m`. Avec scale =
    /// 5000, ça donne ±200 px, à ajuster ensuite par calibration sur la
    /// largeur réelle de l'écran (~400 px de demi-largeur).
    private let scale: Float = 5000

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
              face.isTracked
        else { return }

        let look = face.lookAtPoint   // face-local, en mètres

        // Mapping minimal : lookAtPoint.x → écran X, lookAtPoint.y → écran Y.
        // Le centre de l'écran correspond à lookAtPoint = (0, 0). La
        // calibration en aval applique l'ajustement final (gain, offset,
        // signe selon la convention face/device).
        let bounds = UIScreen.main.bounds
        let screenX = bounds.width  * 0.5 + CGFloat(look.x) * CGFloat(scale)
        let screenY = bounds.height * 0.5 - CGFloat(look.y) * CGFloat(scale)
        let screenPoint = CGPoint(x: screenX, y: screenY)

        let now = CACurrentMediaTime()
        if now - lastLogTime > 2.0 {
            lastLogTime = now
            Self.log.info(
                "lookAt face=(\(look.x, format: .fixed(precision: 4)),\(look.y, format: .fixed(precision: 4)),\(look.z, format: .fixed(precision: 4))) → screen \(Int(screenX))/\(Int(screenY))"
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.onGazeUpdate?(screenPoint)
            self?.onGazeDiagnostic?(CGFloat(look.x), CGFloat(look.y))
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
