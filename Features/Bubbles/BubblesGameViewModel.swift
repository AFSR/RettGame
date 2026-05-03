import Foundation
import CoreGraphics
import Observation
import AudioToolbox
import ARKit
import SwiftUI
import QuartzCore

/// Petit wrapper NSObject pour exposer un `@objc` selector à `CADisplayLink`,
/// sans contraindre le ViewModel à hériter de NSObject.
private final class DisplayLinkProxy: NSObject {
    var onTick: ((CADisplayLink) -> Void)?

    @objc func handle(_ link: CADisplayLink) {
        onTick?(link)
    }
}

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
    /// Mis à jour à 60 Hz mais usage uniquement interne : pas observé pour
    /// éviter d'invalider la vue à chaque frame.
    @ObservationIgnored var rawGazePoint: CGPoint = .zero
    @ObservationIgnored var calibratedGazePoint: CGPoint = .zero
    /// Observé : la vue affiche le point bleu à cette position.
    var lastGazePoint: CGPoint = .zero
    var splashAt: CGPoint? = nil
    var timeRemaining: TimeInterval = 60

    let processor = GazeProcessor()
    let calibrator = GazeCalibrator.shared
    let kalman = GazeKalmanFilter()

    /// Plafond pour éviter le spam visuel et les coûts de hit-test.
    private let maxConcurrentBubbles = 8
    @ObservationIgnored private var spawnTimer: Timer?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var displayLinkProxy = DisplayLinkProxy()
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var lastTickTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var nextColorIndex = 0
    @ObservationIgnored private var canvasSize: CGSize = .zero

    static let minimumCalibrationSamples = EyeGameViewModel.minimumCalibrationSamples
    var hasCalibration: Bool { calibrator.samplesCount >= Self.minimumCalibrationSamples }

    init() {
        applyStoredFilterSettings()
        kalman.setCalibrationConfidence(sampleCount: calibrator.samplesCount)
    }

    deinit {
        displayLink?.invalidate()
        spawnTimer?.invalidate()
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
        self.canvasSize = canvasSize
        score = 0
        bubbles = []
        processor.reset()
        kalman.reset()
        kalman.setCalibrationConfidence(sampleCount: calibrator.samplesCount)
        processor.dwellDuration = speed.dwellDuration
        timeRemaining = duration.seconds
        endDate = Date().addingTimeInterval(duration.seconds)
        state = .playing
        startSpawning()
        startTicking()
    }

    func reset() {
        stopSpawning()
        stopTicking()
        bubbles = []
        splashAt = nil
        state = .configuration
    }

    func updateCanvasSize(_ size: CGSize) {
        canvasSize = size
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

    private func startSpawning() {
        stopSpawning()
        let interval = speed.spawnInterval
        // Timer ajouté en `.common` pour continuer à fournir des bulles pendant
        // les interactions tactiles (sinon il se met en pause en UITrackingMode).
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.spawnOneBubble()
        }
        RunLoop.main.add(timer, forMode: .common)
        spawnTimer = timer
    }

    private func stopSpawning() {
        spawnTimer?.invalidate()
        spawnTimer = nil
    }

    private func spawnOneBubble() {
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
        nextColorIndex = (nextColorIndex + 1) % BubblesPalette.colors.count
        bubbles.append(bubble)
    }

    private func startTicking() {
        stopTicking()
        lastTickTimestamp = CACurrentMediaTime()
        displayLinkProxy.onTick = { [weak self] link in
            self?.tickFromDisplayLink(link)
        }
        let link = CADisplayLink(
            target: displayLinkProxy,
            selector: #selector(DisplayLinkProxy.handle(_:))
        )
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy.onTick = nil
    }

    private func tickFromDisplayLink(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = max(0.001, min(0.1, now - lastTickTimestamp))
        lastTickTimestamp = now
        tick(deltaTime: dt)
    }

    private func tick(deltaTime: TimeInterval) {
        guard state == .playing, let endDate else { return }

        let remaining = endDate.timeIntervalSinceNow
        timeRemaining = max(0, remaining)
        if remaining <= 0 {
            stopSpawning()
            stopTicking()
            state = .finished(score: score)
            bubbles = []
            return
        }

        // Avance les bulles en place — pas d'allocation par frame, et la
        // mutation de `bubbles[i].position.y` déclenche une seule
        // invalidation `@Observable` pour toute la frame.
        let dt = CGFloat(deltaTime)
        var i = bubbles.count
        while i > 0 {
            i -= 1
            bubbles[i].position.y -= bubbles[i].verticalSpeed * dt
            if bubbles[i].position.y + bubbles[i].diameter / 2 < 0 {
                let removedId = bubbles[i].id
                bubbles.remove(at: i)
                // Ne reset le dwell que s'il portait sur la bulle qui vient
                // de disparaître — sinon on tuerait le dwell en cours sur
                // une autre bulle.
                if processor.currentTargetId == removedId {
                    processor.reset()
                }
            }
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
