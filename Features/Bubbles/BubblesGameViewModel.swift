import Foundation
import CoreGraphics
import Observation
import AudioToolbox
import ARKit
import SwiftUI

/// État d'une bulle qui monte à l'écran. Mise à jour par tick à 30 Hz.
struct Bubble: Identifiable, Equatable {
    let id: UUID
    var position: CGPoint
    let diameter: CGFloat
    let colorIndex: Int
    let verticalSpeed: CGFloat // pts/sec, vers le haut

    static func == (lhs: Bubble, rhs: Bubble) -> Bool { lhs.id == rhs.id }
}

enum BubblesPalette {
    static let colors: [Color] = [
        Color(hex: "#FF6F61"),
        Color(hex: "#7B89FF"),
        Color(hex: "#FFD166"),
        Color(hex: "#06D6A0"),
        Color(hex: "#EF476F"),
        Color(hex: "#118AB2"),
    ]
    static func color(at index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

enum BubbleSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .slow: return "Lent"
        case .normal: return "Normal"
        case .fast: return "Rapide"
        }
    }
    var dwellDuration: TimeInterval {
        switch self {
        case .slow: return 1.5
        case .normal: return 1.1
        case .fast: return 0.8
        }
    }
    var spawnInterval: TimeInterval {
        switch self {
        case .slow: return 2.4
        case .normal: return 1.4
        case .fast: return 0.9
        }
    }
    var verticalRange: ClosedRange<CGFloat> {
        switch self {
        case .slow: return 55...85
        case .normal: return 85...130
        case .fast: return 130...190
        }
    }
}

enum BubbleDuration: Int, CaseIterable, Identifiable {
    case short = 30
    case standard = 60
    case long = 120
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .short: return "30 s"
        case .standard: return "1 min"
        case .long: return "2 min"
        }
    }
    var seconds: TimeInterval { TimeInterval(rawValue) }
}

@Observable
final class BubblesGameViewModel {
    enum GameState: Equatable {
        case configuration
        case playing
        case finished(score: Int)
    }

    // Configuration parent
    var duration: BubbleDuration = .standard
    var speed: BubbleSpeed = .normal
    var bubbleSize: TargetSize = .normal
    var showGazeIndicator: Bool = true

    // État de jeu
    var state: GameState = .configuration
    var bubbles: [Bubble] = []
    var score: Int = 0
    var rawGazePoint: CGPoint = .zero
    var calibratedGazePoint: CGPoint = .zero
    var lastGazePoint: CGPoint = .zero
    var splashAt: CGPoint? = nil
    var timeRemaining: TimeInterval = 60

    let processor = GazeProcessor()
    let calibrator = GazeCalibrator.shared
    let kalman = GazeKalmanFilter()

    /// Plafond pour éviter le spam visuel et les coûts de hit-test.
    private let maxConcurrentBubbles = 8
    private var spawnTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var endDate: Date?
    private var nextColorIndex = 0

    static let minimumCalibrationSamples = EyeGameViewModel.minimumCalibrationSamples
    var hasCalibration: Bool { calibrator.samplesCount >= Self.minimumCalibrationSamples }

    init() {
        applyStoredFilterSettings()
        kalman.setCalibrationConfidence(sampleCount: calibrator.samplesCount)
    }

    func applyStoredFilterSettings() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: EyeGameSettings.smoothingEnabledKey) as? Bool ?? true
        let strength = defaults.object(forKey: EyeGameSettings.smoothingStrengthKey) as? Double
            ?? EyeGameSettings.defaultSmoothingStrength
        kalman.enabled = enabled
        kalman.smoothingStrength = strength
    }

    func isEyeTrackingAvailable() -> Bool {
        ARFaceTrackingConfiguration.isSupported
    }

    @discardableResult
    private func recordCalibrationSample(actual: CGPoint) -> Bool {
        guard rawGazePoint != .zero else { return false }
        calibrator.addSample(raw: rawGazePoint, actual: actual)
        kalman.setCalibrationConfidence(sampleCount: calibrator.samplesCount)
        let newCalibrated = calibrator.apply(rawGazePoint)
        calibratedGazePoint = newCalibrated
        lastGazePoint = kalman.filter(measurement: newCalibrated)
        return true
    }

    func resetCalibration() {
        calibrator.reset()
        kalman.reset()
        kalman.setCalibrationConfidence(sampleCount: 0)
        calibratedGazePoint = rawGazePoint
        lastGazePoint = rawGazePoint
    }

    // MARK: - Game lifecycle

    func launchPlaying() {
        state = .playing
    }

    func start(in canvasSize: CGSize) {
        score = 0
        bubbles = []
        processor.reset()
        kalman.reset()
        kalman.setCalibrationConfidence(sampleCount: calibrator.samplesCount)
        processor.dwellDuration = speed.dwellDuration
        timeRemaining = duration.seconds
        endDate = Date().addingTimeInterval(duration.seconds)
        state = .playing
        startSpawning(in: canvasSize)
        startTicking(canvasSize: canvasSize)
    }

    func reset() {
        spawnTask?.cancel()
        tickTask?.cancel()
        bubbles = []
        splashAt = nil
        state = .configuration
    }

    /// Pipeline : raw (ARKit) → calibration → Kalman → dwell sur les bulles.
    /// Lorsque le dwell réussit, la bulle qui a été regardée fournit un échantillon
    /// de calibration supplémentaire (la position d'une bulle visée par dwell est
    /// une vérité-terrain raisonnable).
    func handleGaze(_ rawPoint: CGPoint, in canvasSize: CGSize) {
        rawGazePoint = rawPoint
        let calibrated = calibrator.apply(rawPoint)
        calibratedGazePoint = calibrated
        let smoothed = kalman.filter(measurement: calibrated)
        lastGazePoint = smoothed

        guard state == .playing else { return }
        let targets = bubbles.map {
            GameTarget(id: $0.id, position: $0.position, diameter: $0.diameter)
        }
        if let hitId = processor.update(gazePoint: smoothed, targets: targets),
           let bubble = bubbles.first(where: { $0.id == hitId }) {
            recordCalibrationSample(actual: bubble.position)
            popBubble(id: hitId)
        }
    }

    /// Tap parent : on enregistre l'échantillon de calibration et, si une bulle
    /// est sous le doigt, on la fait éclater (aide quand l'enfant n'arrive pas
    /// à dwell).
    func recordCalibrationTap(at location: CGPoint, canvasSize: CGSize) {
        recordCalibrationSample(actual: location)
        guard state == .playing else { return }
        if let bubble = bubbles.first(where: {
            hypot($0.position.x - location.x, $0.position.y - location.y) < $0.diameter / 2 + 30
        }) {
            popBubble(id: bubble.id)
        }
    }

    // MARK: - Internals

    private func popBubble(id: UUID) {
        guard let idx = bubbles.firstIndex(where: { $0.id == id }) else { return }
        let bubble = bubbles.remove(at: idx)
        score += 1
        splashAt = bubble.position
        AudioServicesPlaySystemSound(1104)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            await MainActor.run {
                if self?.splashAt == bubble.position {
                    self?.splashAt = nil
                }
            }
        }
    }

    private func startSpawning(in canvasSize: CGSize) {
        spawnTask?.cancel()
        let spawnInterval = speed.spawnInterval
        spawnTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await MainActor.run { self.spawnOneBubble(in: canvasSize) }
                try? await Task.sleep(nanoseconds: UInt64(spawnInterval * 1_000_000_000))
            }
        }
    }

    @MainActor
    private func spawnOneBubble(in canvasSize: CGSize) {
        guard state == .playing else { return }
        guard bubbles.count < maxConcurrentBubbles else { return }
        let diameter = bubbleSize.diameter
        let x = CGFloat.random(in: diameter ... max(diameter, canvasSize.width - diameter))
        let y = canvasSize.height + diameter / 2
        let vSpeed = CGFloat.random(in: speed.verticalRange)
        let bubble = Bubble(
            id: UUID(),
            position: CGPoint(x: x, y: y),
            diameter: diameter,
            colorIndex: nextColorIndex,
            verticalSpeed: vSpeed
        )
        nextColorIndex += 1
        bubbles.append(bubble)
    }

    private func startTicking(canvasSize: CGSize) {
        tickTask?.cancel()
        let frame = 1.0 / 30.0
        let frameNanos = UInt64(frame * 1_000_000_000)
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await MainActor.run { self.tick(deltaTime: frame, canvasSize: canvasSize) }
                try? await Task.sleep(nanoseconds: frameNanos)
            }
        }
    }

    @MainActor
    private func tick(deltaTime: TimeInterval, canvasSize: CGSize) {
        guard state == .playing, let endDate else { return }

        let remaining = endDate.timeIntervalSinceNow
        timeRemaining = max(0, remaining)
        if remaining <= 0 {
            spawnTask?.cancel()
            tickTask?.cancel()
            state = .finished(score: score)
            bubbles = []
            return
        }

        // Avance les bulles (immutables → on remplace).
        let dt = CGFloat(deltaTime)
        bubbles = bubbles.compactMap { b in
            let newY = b.position.y - b.verticalSpeed * dt
            if newY + b.diameter / 2 < 0 {
                processor.reset() // relâche un dwell éventuel sur cette bulle
                return nil
            }
            return Bubble(
                id: b.id,
                position: CGPoint(x: b.position.x, y: newY),
                diameter: b.diameter,
                colorIndex: b.colorIndex,
                verticalSpeed: b.verticalSpeed
            )
        }
    }

    // MARK: - Simulator mock

    #if targetEnvironment(simulator)
    private var mockTimer: Timer?
    func startMockGaze(canvasSize: CGSize) {
        mockTimer?.invalidate()
        mockTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let b = self.bubbles.randomElement() {
                let jitter: CGFloat = 80
                let p = CGPoint(
                    x: b.position.x + CGFloat.random(in: -jitter...jitter),
                    y: b.position.y + CGFloat.random(in: -jitter...jitter)
                )
                self.handleGaze(p, in: canvasSize)
            }
        }
    }

    func stopMockGaze() {
        mockTimer?.invalidate()
        mockTimer = nil
    }
    #endif
}
