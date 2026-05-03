import SwiftUI

/// Session de calibration guidée : cibles successives sur une grille 3×3
/// (cyclées indéfiniment). Le parent attire le regard de l'enfant sur chaque
/// cible et tape n'importe où à l'écran quand l'enfant la regarde — chaque tap
/// enregistre une paire `(rawGaze courant, position cible)` dans le calibrateur
/// partagé `GazeCalibrator.shared`.
///
/// L'écran ne s'auto-ferme pas : une fois le minimum atteint (`minimumSamples`),
/// le bouton "Terminer" apparaît et l'utilisateur peut continuer à ajouter
/// autant de points qu'il le souhaite avant de quitter. Les samples sont
/// persistés à chaque tap, donc fermer ne perd jamais le travail déjà fait.
struct GazeCalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    private let calibrator = GazeCalibrator.shared
    /// Filtre Kalman local à la session de calibration : permet d'afficher un
    /// point bleu lissé qui suit le regard, sans toucher au filtre du jeu en
    /// cours côté game-VM.
    @State private var kalman = GazeKalmanFilter()
    @State private var rawGazePoint: CGPoint = .zero
    @State private var displayPoint: CGPoint = .zero

    private let normalizedPositions: [CGPoint] = [
        CGPoint(x: 0.15, y: 0.22), CGPoint(x: 0.50, y: 0.22), CGPoint(x: 0.85, y: 0.22),
        CGPoint(x: 0.15, y: 0.50), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.85, y: 0.50),
        CGPoint(x: 0.15, y: 0.78), CGPoint(x: 0.50, y: 0.78), CGPoint(x: 0.85, y: 0.78),
    ]

    let minimumSamples: Int

    init(minimumSamples: Int = EyeGameViewModel.minimumCalibrationSamples) {
        self.minimumSamples = minimumSamples
    }

    @State private var currentIndex: Int = 0
    @State private var canvasSize: CGSize = .zero
    @State private var pulse: Bool = false
    @State private var showRejectedFeedback: Bool = false
    @State private var splashAtTarget: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // ARKit en arrière-plan : on lit le regard, on l'applique au
                // calibrateur partagé pour le point bleu d'affichage.
                ARFaceView { point in
                    rawGazePoint = point
                    let calibrated = calibrator.apply(point)
                    displayPoint = kalman.filter(measurement: calibrated)
                }
                .allowsHitTesting(false)
                .opacity(0.001)

                // Indicateur de regard (bleu) — non interactif, suit displayPoint.
                GazeIndicator()
                    .position(displayPoint)
                    .allowsHitTesting(false)

                // Couche de capture des taps : au-dessus de l'AR + indicateur,
                // mais sous les visuels de cible (qui ne capturent pas) et la UI.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap() }

                // Cible courante — purement visuelle.
                let p = currentPosition(in: geo.size)
                TargetDot(diameter: 110, pulsing: pulse, splashing: splashAtTarget)
                    .position(p)
                    .allowsHitTesting(false)

                VStack {
                    HStack {
                        Button("Fermer") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .tint(.afsrPurpleAdaptive)
                        Spacer()
                        ProgressBadge(
                            samples: calibrator.samplesCount,
                            minimum: minimumSamples
                        )
                    }
                    .padding()

                    Spacer()

                    if showRejectedFeedback {
                        FeedbackBanner(
                            text: "Visage non détecté — placez l'enfant face à la caméra avant de taper.",
                            color: .afsrEmergency
                        )
                        .transition(.opacity)
                        .padding(.horizontal, 24)
                    } else {
                        InstructionBanner()
                            .padding(.horizontal, 24)
                    }

                    if calibrator.samplesCount >= minimumSamples {
                        AFSRPrimaryButton(title: "Terminer", icon: "checkmark.circle.fill") {
                            dismiss()
                        }
                        .padding()
                    } else {
                        let needed = minimumSamples - calibrator.samplesCount
                        Text("Encore \(needed) point\(needed > 1 ? "s" : "") avant de pouvoir terminer.")
                            .font(AFSRFont.caption())
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.bottom, 24)
                    }
                }
            }
            .onAppear {
                canvasSize = geo.size
                pulse = true
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    private func currentPosition(in size: CGSize) -> CGPoint {
        let n = normalizedPositions[currentIndex % normalizedPositions.count]
        return CGPoint(x: n.x * size.width, y: n.y * size.height)
    }

    private func handleTap() {
        let target = currentPosition(in: canvasSize)
        guard rawGazePoint != .zero else {
            withAnimation(.easeInOut(duration: 0.2)) { showRejectedFeedback = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.easeInOut(duration: 0.3)) { showRejectedFeedback = false }
            }
            return
        }
        calibrator.addSample(raw: rawGazePoint, actual: target)
        showRejectedFeedback = false

        withAnimation(.easeOut(duration: 0.18)) { splashAtTarget = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            splashAtTarget = false
            withAnimation(.easeInOut(duration: 0.25)) {
                currentIndex = currentIndex + 1
            }
        }
    }
}

private struct GazeIndicator: View {
    var body: some View {
        Circle()
            .fill(Color.blue.opacity(0.55))
            .frame(width: 26, height: 26)
            .overlay(
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 2)
            )
            .shadow(color: .blue.opacity(0.6), radius: 8)
            .accessibilityHidden(true)
    }
}

private struct TargetDot: View {
    let diameter: CGFloat
    let pulsing: Bool
    let splashing: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.afsrPurple.opacity(0.4), lineWidth: 4)
                .frame(width: diameter + 30, height: diameter + 30)
                .scaleEffect(pulsing ? 1.08 : 0.94)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
            Circle()
                .fill(Color.afsrPurple)
                .frame(width: diameter, height: diameter)
                .scaleEffect(splashing ? 1.25 : 1.0)
                .opacity(splashing ? 0.5 : 1.0)
            Text("👀")
                .font(.system(size: diameter * 0.6))
        }
        .accessibilityLabel("Cible de calibration")
    }
}

private struct ProgressBadge: View {
    let samples: Int
    let minimum: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .foregroundStyle(samples >= minimum ? Color.afsrSuccess : Color.afsrPurpleLight)
            Text("\(samples)")
                .font(AFSRFont.headline())
                .monospacedDigit()
            Text("/ \(minimum) min").font(AFSRFont.caption()).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
    }
}

private struct InstructionBanner: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("Tapez l'écran quand votre enfant regarde la cible")
                .font(AFSRFont.headline())
            Text("Le point bleu suit son regard. La cible cycle sur 9 positions, refaites-en autant que vous voulez.")
                .font(AFSRFont.caption())
                .foregroundStyle(.white.opacity(0.85))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct FeedbackBanner: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(color)
            Text(text)
                .font(AFSRFont.body(15))
                .foregroundStyle(.white)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
