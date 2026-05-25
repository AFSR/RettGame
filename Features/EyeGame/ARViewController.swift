import SwiftUI
import ARKit
import os.log

/// Wrapper UIKit pour le suivi du regard.
///
/// **Stratégie actuelle (V3) — basée sur les blendShapes oculaires** :
///
/// Apple expose dans `faceAnchor.blendShapes` 8 valeurs angulaires normalisées [0, 1]
/// décrivant la direction du regard de chaque œil indépendamment :
/// `eyeLookIn{Right,Left}` (vers le nez), `eyeLookOut{Right,Left}` (vers l'extérieur),
/// `eyeLookUp{Right,Left}` (vers le haut), `eyeLookDown{Right,Left}` (vers le bas).
///
/// Ces valeurs sont mesurées via la caméra TrueDepth + l'inférence ML interne d'ARKit
/// — elles intègrent déjà la distance du visage, l'écart inter-pupillaire, l'angle de tête.
/// Aucune calibration géométrique ne peut faire mieux que ce signal natif.
///
/// On combine les 8 valeurs en un vecteur 2D :
///   horizontal = ((outR + inL) − (outL + inR)) / 2   →  −1 (gauche) … +1 (droite)
///   vertical   = ((upR + upL)  − (dnR + dnL))  / 2   →  −1 (bas)    … +1 (haut)
///
/// Puis amplification × rotation selon l'orientation interface → coordonnées écran.
/// La calibration tap absorbe l'amplitude individuelle.
final class ARFaceViewController: UIViewController, ARSessionDelegate {

    private static let log = Logger(subsystem: "fr.afsr.RettApp", category: "EyeGame.AR")

    let arSession = ARSession()
    var onGazeUpdate: ((CGPoint) -> Void)?

    /// Amplification du signal blendShape vers l'écran. Au-dessus de 1, le regard
    /// couvre tout l'écran avec une amplitude oculaire plus modeste (typique des
    /// enfants qui ne tournent pas beaucoup les yeux). 2.4 → un regard à ±30 % de
    /// l'amplitude oculaire maximale couvre déjà ~70 % de l'écran, ce qui donne
    /// suffisamment de range au calibrateur pour apprendre une pente non
    /// dégénérée même avec un signal modeste.
    private let amplification: CGFloat = 2.4

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
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              faceAnchor.isTracked else { return }

        let blends = faceAnchor.blendShapes
        @inline(__always) func b(_ key: ARFaceAnchor.BlendShapeLocation) -> CGFloat {
            CGFloat(truncating: blends[key] ?? 0)
        }

        // Directions oculaires (par œil)
        let outR = b(.eyeLookOutRight),   inR = b(.eyeLookInRight)
        let outL = b(.eyeLookOutLeft),    inL = b(.eyeLookInLeft)
        let upR  = b(.eyeLookUpRight),    upL = b(.eyeLookUpLeft)
        let dnR  = b(.eyeLookDownRight),  dnL = b(.eyeLookDownLeft)

        // Combinaison binoculaire :
        //   regarder à droite : œil droit "outRight" + œil gauche "inLeft" actifs
        //   regarder à gauche : œil droit "inRight" + œil gauche "outLeft" actifs
        let horizontal = ((outR + inL) - (outL + inR)) / 2  // ≈ [-1, 1]
        let vertical   = ((upR + upL) - (dnR + dnL)) / 2    // ≈ [-1, 1]

        // Mapping en coordonnées d'interface — varie selon l'orientation
        let bounds = UIScreen.main.bounds
        let orientation = currentInterfaceOrientation()
        let screenPoint = mapToScreen(horizontal: horizontal, vertical: vertical,
                                      bounds: bounds, orientation: orientation)

        // Diagnostic : log toutes les 2 s
        let now = CACurrentMediaTime()
        if now - lastLogTime > 2.0 {
            lastLogTime = now
            Self.log.info(
                "blend h=\(horizontal, format: .fixed(precision: 3)) v=\(vertical, format: .fixed(precision: 3)) → screen \(Int(screenPoint.x))/\(Int(screenPoint.y)) orient=\(self.orientationName(orientation))"
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.onGazeUpdate?(screenPoint)
        }
    }

    // MARK: - Orientation handling

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        if let scene = view.window?.windowScene {
            return scene.interfaceOrientation
        }
        // Fallback : déduire de l'aspect des bounds
        return UIScreen.main.bounds.width > UIScreen.main.bounds.height ? .landscapeRight : .portrait
    }

    private func orientationName(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "P"
        case .portraitUpsideDown: return "P↻"
        case .landscapeLeft: return "L←"
        case .landscapeRight: return "L→"
        default: return "?"
        }
    }

    /// Convertit `(horizontal, vertical)` ∈ [-1, 1] en `CGPoint` écran.
    ///
    /// **Indépendant de l'orientation device.** Les 8 blendShapes oculaires
    /// d'ARKit sont en repère **face/utilisateur** : `eyeLookOutRight`
    /// signifie "le pupille droite regarde vers la droite de l'utilisateur",
    /// peu importe comment le device est tenu. Comme iOS rétablit déjà
    /// l'image à l'endroit pour l'utilisateur (le contenu rendu en
    /// landscape est physiquement orienté pour qu'il le voie droit), le
    /// mapping userRight → screenRight reste vrai dans toutes les
    /// orientations. On ne switche plus selon l'interface — le précédent
    /// switch était bâti sur l'hypothèse erronée que les blendShapes sont
    /// en repère caméra.
    private func mapToScreen(horizontal: CGFloat, vertical: CGFloat,
                             bounds: CGRect, orientation: UIInterfaceOrientation) -> CGPoint {
        let h = horizontal * amplification
        let v = vertical   * amplification

        // userRight → screenRight, userUp → screenUp (= y faible côté iOS).
        let nx = h
        let ny = -v

        let x = (nx * 0.5 + 0.5) * bounds.width
        let y = (ny * 0.5 + 0.5) * bounds.height
        return CGPoint(x: x, y: y)
    }
}

/// Représentable SwiftUI pour le tracking facial.
struct ARFaceView: UIViewControllerRepresentable {
    let onGazeUpdate: (CGPoint) -> Void

    func makeUIViewController(context: Context) -> ARFaceViewController {
        let vc = ARFaceViewController()
        vc.onGazeUpdate = onGazeUpdate
        return vc
    }

    func updateUIViewController(_ vc: ARFaceViewController, context: Context) {
        vc.onGazeUpdate = onGazeUpdate
    }
}
