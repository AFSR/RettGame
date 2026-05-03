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

    /// Progression actuelle du dwell sur la cible courante (0 → 1).
    private(set) var dwellProgress: Double = 0
    private(set) var currentTargetId: UUID?

    private var gazeStartTime: Date?

    /// Met à jour l'état du dwell à partir d'un point de regard et retourne un id de cible si déclenchée.
    func update(gazePoint: CGPoint, targets: [GameTarget]) -> UUID? {
        guard let hit = targets.first(where: { distance($0.position, gazePoint) < radiusFor($0) }) else {
            reset()
            return nil
        }

        if currentTargetId == hit.id, let start = gazeStartTime {
            let elapsed = Date().timeIntervalSince(start)
            dwellProgress = min(1.0, elapsed / dwellDuration)
            if elapsed >= dwellDuration {
                let triggered = hit.id
                reset()
                return triggered
            }
        } else {
            currentTargetId = hit.id
            gazeStartTime = Date()
            dwellProgress = 0
        }
        return nil
    }

    func reset() {
        currentTargetId = nil
        gazeStartTime = nil
        dwellProgress = 0
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func radiusFor(_ target: GameTarget) -> CGFloat {
        max(targetRadius, target.diameter / 2 + 20)
    }
}
