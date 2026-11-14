import SwiftUI
import QuartzCore

/// Session de calibration guidée : cibles successives sur une grille 3×3 (cyclées
/// indéfiniment). Le parent attire le regard de l'enfant sur chaque cible et tape
/// n'importe où à l'écran quand l'enfant la regarde ; chaque tap enregistre
/// `(features du regard, position de la cible)` dans `GazeCalibrator.shared`.
///
/// La vue occupe tout l'écran (origine 0,0) : les positions des cibles sont ainsi dans le
/// même repère que celui du regard et des écrans de jeu.
///
/// Hiérarchie visuelle volontairement asymétrique : la cible est dominante (taille,
/// couleurs, halo pulsant), le reste est discret pour ne pas distraire le regard.
struct GazeCalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    private let calibrator = GazeCalibrator.shared
    @State private var kalman = GazeKalmanFilter()
    @State private var rawGazePoint: CGPoint = .zero
    @State private var calibratedPoint: CGPoint = .zero
    @State private var displayPoint: CGPoint = .zero
    @State private var features: [Double] = []
    @State private var lastFeaturesUpdate: CFTimeInterval = 0

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
                // Fond sombre légèrement bleuté : repose l'œil et fait ressortir la cible.
                LinearGradient(
                    colors: [Color(hex: "#0F1726"), Color(hex: "#1B2438")],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ARFaceView(
                    onGazeUpdate: { point in
                        rawGazePoint = point
                        let calibrated = calibrator.apply(point)
                        calibratedPoint = calibrated
                        displayPoint = kalman.filter(measurement: calibrated)
                    },
                    onFeatures: { values in
                        // Le HUD n'a pas besoin du 60 Hz : on limite les invalidations de la vue.
                        let now = CACurrentMediaTime()
                        if now - lastFeaturesUpdate > 0.1 {
                            lastFeaturesUpdate = now
                            features = values
                        }
                    }
                )
                .allowsHitTesting(false)
                .opacity(0.001)

                // Diagnostic : rouge = estimation ARKit brute, jaune = après calibration,
                // bleu = sortie finale (après Kalman). Rouge et jaune sont superposés tant
                // que la calibration n'est pas entraînée.
                DiagnosticDot(color: .red, diameter: 14).position(rawGazePoint).allowsHitTesting(false)
                DiagnosticDot(color: .yellow, diameter: 14).position(calibratedPoint).allowsHitTesting(false)
                GazeIndicator()
                    .position(displayPoint)
                    .allowsHitTesting(false)

                // Capture des taps : sous les visuels (qui ne capturent rien), au-dessus de l'AR.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap() }

                BigTarget(diameter: 180, pulsing: pulse, splashing: splashAtTarget)
                    .position(currentPosition(in: geo.size))
                    .allowsHitTesting(false)

                VStack {
                    HStack(alignment: .top) {
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

                        SubtleProgressBadge(
                            samples: calibrator.samplesCount,
                            minimum: minimumSamples
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, geo.safeAreaInsets.top + 8)

                    Spacer()

                    DiagnosticReadout(
                        raw: rawGazePoint,
                        calibrated: calibratedPoint,
                        smoothed: displayPoint,
                        canvas: geo.size,
                        features: features,
                        samplesCount: calibrator.samplesCount,
                        minimumSamples: minimumSamples,
                        isTrained: calibrator.isTrained,
                        report: calibrator.report
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

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
                        // La précision continue de s'améliorer jusqu'à ~18 points.
                        if calibrator.samplesCount < 18 {
                            Text("Continuez : précision améliorée jusqu'à ~18 points")
                                .font(AFSRFont.caption(11))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.bottom, 4)
                        }
                        Button {
                            dismiss()
                        } label: {
                            Label("Terminer", systemImage: "checkmark")
                                .font(AFSRFont.headline(15))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20).padding(.vertical, 12)
                                .background(Color.afsrSuccess.opacity(0.85), in: Capsule())
                        }
                        .padding(.bottom, geo.safeAreaInsets.bottom + 16)
                    } else {
                        Color.clear.frame(height: geo.safeAreaInsets.bottom + 16)
                    }
                }
            }
            .onAppear {
                canvasSize = geo.size
                pulse = true
                calibrator.tune(kalman)
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .navigationBarBackButtonHidden(true)
    }

    private func currentPosition(in size: CGSize) -> CGPoint {
        let n = normalizedPositions[currentIndex % normalizedPositions.count]
        return CGPoint(x: n.x * size.width, y: n.y * size.height)
    }

    private func handleTap() {
        guard calibrator.addSample(target: currentPosition(in: canvasSize)) else {
            withAnimation(.easeInOut(duration: 0.2)) { showRejectedFeedback = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.easeInOut(duration: 0.3)) { showRejectedFeedback = false }
            }
            return
        }
        showRejectedFeedback = false
        calibrator.tune(kalman)

        withAnimation(.easeOut(duration: 0.18)) { splashAtTarget = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            splashAtTarget = false
            withAnimation(.easeInOut(duration: 0.25)) {
                currentIndex += 1
            }
            // Le sample suivant repart d'une fenêtre de lissage fraîche.
            calibrator.resetEMA()
        }
    }
}

private struct DiagnosticDot: View {
    let color: Color
    let diameter: CGFloat
    var body: some View {
        Circle()
            .fill(color.opacity(0.85))
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct DiagnosticReadout: View {
    let raw: CGPoint
    let calibrated: CGPoint
    let smoothed: CGPoint
    let canvas: CGSize
    let features: [Double]
    let samplesCount: Int
    let minimumSamples: Int
    let isTrained: Bool
    let report: GazeCalibrator.FitReport

    private var featuresLine: String {
        guard features.count == GazeCalibrator.featureCount else { return "features : en attente d'ARKit…" }
        return String(format: "impact x=%+6.1f y=%+6.1f mm   blend h=%+.3f v=%+.3f",
                      features[0] * 1000, features[1] * 1000, features[2], features[3])
    }

    private var modelLine: String {
        guard isTrained else {
            let missing = max(0, minimumSamples - samplesCount)
            return "pas encore calibré — encore \(missing) point(s)"
        }
        return String(format: "modèle %d/%d pts · erreur x=±%.0fpx (R² %.2f) y=±%.0fpx (R² %.2f)",
                      report.sampleCount, samplesCount, report.looX, report.looR2X, report.looY, report.looR2Y)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(featuresLine)
                .foregroundStyle(.white.opacity(0.85))
            row(color: .red, label: "raw", pt: raw)
            row(color: .yellow, label: "cal", pt: calibrated)
            row(color: .blue, label: "out", pt: smoothed)
            Text("fenêtre \(Int(canvas.width))×\(Int(canvas.height))")
                .foregroundStyle(.white.opacity(0.6))
            Text(modelLine)
                .foregroundStyle(isTrained ? Color.afsrSuccess.opacity(0.9) : .white.opacity(0.6))
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(color: Color, label: String, pt: CGPoint) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.white.opacity(0.75))
            Text(String(format: "%4d,%4d", Int(pt.x), Int(pt.y)))
                .monospacedDigit()
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

            Circle()
                .stroke(Color(hex: "#FFD93D"), lineWidth: 6)
                .frame(width: diameter + 36, height: diameter + 36)
                .scaleEffect(pulsing ? 1.10 : 0.96)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)

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
