import SwiftUI

/// Session de calibration guidée : cibles successives sur une grille 3×3
/// (cyclées indéfiniment). Le parent attire le regard de l'enfant sur chaque
/// cible et tape n'importe où à l'écran quand l'enfant la regarde — chaque tap
/// enregistre une paire `(rawGaze courant, position cible)` dans le calibrateur
/// partagé `GazeCalibrator.shared`.
///
/// Hiérarchie visuelle volontairement asymétrique : la cible est dominante
/// (taille, couleurs, halo pulsant), tout le reste (bouton Fermer, badge de
/// progression, bannière d'instructions) est discret pour ne pas distraire le
/// regard de l'enfant.
struct GazeCalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    private let calibrator = GazeCalibrator.shared
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
                // Fond sombre, légèrement bleuté pour reposer l'œil et faire
                // ressortir le jaune/orange de la cible.
                LinearGradient(
                    colors: [Color(hex: "#0F1726"), Color(hex: "#1B2438")],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ARFaceView { point in
                    rawGazePoint = point
                    let calibrated = calibrator.apply(point)
                    displayPoint = kalman.filter(measurement: calibrated)
                }
                .allowsHitTesting(false)
                .opacity(0.001)

                // Indicateur de regard (bleu) — discret, taille réduite.
                GazeIndicator()
                    .position(displayPoint)
                    .allowsHitTesting(false)

                // Couche de capture des taps : sous les visuels (qui ne
                // capturent rien) mais au-dessus de l'AR.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap() }

                // Cible — dominante : grande, halo pulsant, couleur chaude.
                let p = currentPosition(in: geo.size)
                BigTarget(diameter: 180, pulsing: pulse, splashing: splashAtTarget)
                    .position(p)
                    .allowsHitTesting(false)

                VStack {
                    HStack(alignment: .top) {
                        // Bouton Fermer : icône seule, discrète.
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Fermer")

                        Spacer()

                        // Compteur : minuscule, presque invisible.
                        SubtleProgressBadge(
                            samples: calibrator.samplesCount,
                            minimum: minimumSamples
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()

                    if showRejectedFeedback {
                        FeedbackBanner(
                            text: "Visage non détecté — placez l'enfant face à la caméra.",
                            color: .afsrEmergency
                        )
                        .transition(.opacity)
                        .padding(.horizontal, 24)
                    } else {
                        SubtleHint()
                            .padding(.horizontal, 24)
                    }

                    if calibrator.samplesCount >= minimumSamples {
                        Button {
                            dismiss()
                        } label: {
                            Label("Terminer", systemImage: "checkmark")
                                .font(AFSRFont.headline(15))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20).padding(.vertical, 12)
                                .background(Color.afsrSuccess.opacity(0.85), in: Capsule())
                        }
                        .padding(.bottom, 16)
                    } else {
                        Color.clear.frame(height: 16)
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
            .fill(Color.blue.opacity(0.45))
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
            .shadow(color: .blue.opacity(0.4), radius: 4)
            .accessibilityHidden(true)
    }
}

/// Cible large + halo pulsant + dégradé chaud, conçue pour capter le regard.
private struct BigTarget: View {
    let diameter: CGFloat
    let pulsing: Bool
    let splashing: Bool

    var body: some View {
        ZStack {
            // Halo extérieur : très large, animé, opacité basse.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: "#FFD93D").opacity(0.35),
                            Color(hex: "#FFD93D").opacity(0),
                        ],
                        center: .center,
                        startRadius: diameter * 0.4,
                        endRadius: diameter * 1.4
                    )
                )
                .frame(width: diameter * 2.8, height: diameter * 2.8)
                .scaleEffect(pulsing ? 1.05 : 0.85)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)

            // Anneau pulsant net.
            Circle()
                .stroke(Color(hex: "#FFD93D"), lineWidth: 6)
                .frame(width: diameter + 36, height: diameter + 36)
                .scaleEffect(pulsing ? 1.10 : 0.96)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)

            // Disque central avec dégradé chaud.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: "#FF8C42"), Color(hex: "#E83A3A")],
                        center: .topLeading,
                        startRadius: 8,
                        endRadius: diameter
                    )
                )
                .frame(width: diameter, height: diameter)
                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 3))
                .shadow(color: Color(hex: "#FFD93D").opacity(0.6), radius: 24)
                .scaleEffect(splashing ? 1.25 : 1.0)
                .opacity(splashing ? 0.55 : 1.0)

            Text("👀")
                .font(.system(size: diameter * 0.55))
        }
        .accessibilityLabel("Cible de calibration")
    }
}

/// Compteur minimal : juste deux nombres séparés par un slash, sans icône.
private struct SubtleProgressBadge: View {
    let samples: Int
    let minimum: Int

    var body: some View {
        Text("\(samples) / \(minimum)")
            .font(AFSRFont.caption(13))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(samples >= minimum ? 0.85 : 0.55))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Indication discrète au lieu d'une bannière imposante.
private struct SubtleHint: View {
    var body: some View {
        Text("Tape l'écran quand l'enfant fixe la cible")
            .font(AFSRFont.caption())
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
    }
}

private struct FeedbackBanner: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(color)
            Text(text)
                .font(AFSRFont.caption())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
