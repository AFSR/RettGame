import Foundation
import CoreGraphics
import Observation

struct GameTarget: Identifiable, Equatable {
    let id: UUID
    var position: CGPoint
    var diameter: CGFloat
}

@Observable
final class GazeProcessor {
    var dwellDuration: TimeInterval = 1.5
    var targetRadius: CGFloat = 80
    /// Coefficient multiplicateur du rayon utilisé en sortie de dwell.
    /// > 1 → hystérésis : on garde la fixation tant que le regard reste dans
    /// `release × engage`, même s'il sort du rayon strict d'accroche. Évite
    /// qu'un micro-tremblement remette la progression à zéro.
    var releaseMultiplier: CGFloat = 1.6

    /// Progression actuelle du dwell sur la cible courante (0 → 1).
    private(set) var dwellProgress: Double = 0
    private(set) var currentTargetId: UUID?

    private var gazeStartTime: Date?

    /// Met à jour l'état du dwell et retourne un id de cible si le dwell est complet.
    ///
    /// Algorithme :
    /// 1. Si on est déjà en train de dwell sur une cible existante et que le
    ///    regard reste dans le **rayon de release** (engage × `releaseMultiplier`),
    ///    on accumule. Pas de reset sur micro-jitter.
    /// 2. Sinon, on cherche une nouvelle cible avec le rayon strict d'engage.
    ///    Si on en trouve une, on démarre un nouveau dwell. Sinon, on reset.
    func update(gazePoint: CGPoint, targets: [GameTarget]) -> UUID? {
        // (1) On tente de prolonger le dwell en cours avec un rayon relâché.
        if let currentId = currentTargetId,
           let current = targets.first(where: { $0.id == currentId }) {
            let releaseR = radiusFor(current) * releaseMultiplier
            if distance(current.position, gazePoint) < releaseR {
                if let start = gazeStartTime {
                    let elapsed = Date().timeIntervalSince(start)
                    dwellProgress = min(1.0, elapsed / dwellDuration)
                    if elapsed >= dwellDuration {
                        let triggered = currentId
                        reset()
                        return triggered
                    }
                }
                return nil
            }
            // Le regard a franchement quitté la cible → on relâche.
            reset()
        }

        // (2) Recherche d'une nouvelle cible avec le rayon strict.
        guard let hit = targets.first(where: { distance($0.position, gazePoint) < radiusFor($0) }) else {
            return nil
        }
        currentTargetId = hit.id
        gazeStartTime = Date()
        dwellProgress = 0
        return nil
    }

    func reset() {
        currentTargetId = nil
        gazeStartTime = nil
        dwellProgress = 0
    }

    @inline(__always)
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    @inline(__always)
    private func radiusFor(_ target: GameTarget) -> CGFloat {
        max(targetRadius, target.diameter / 2 + 20)
    }
}
