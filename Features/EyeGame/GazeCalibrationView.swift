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
    @State private var calibratedPoint: CGPoint = .zero
    @State private var displayPoint: CGPoint = .zero

    /// Moyenne mobile exponentielle du point raw, utilisée à la place du raw
    /// instantané (très bruité) lors de l'enregistrement d'un échantillon.
    /// α = 0.15 → constante de temps ≈ 100 ms à 60 Hz. Réduit fortement le
    /// biais d'atténuation de la régression OLS du calibrateur.
    @State private var emaRawPoint: CGPoint = .zero
    @State private var emaInitialized: Bool = false
    private let emaAlpha: CGFloat = 0.15

    /// Valeurs brutes h, v ∈ [-1, 1] sorties d'ARKit avant tout mapping écran.
    /// Affichées dans le readout de diagnostic.
    @State private var blendH: CGFloat = 0
    @State private var blendV: CGFloat = 0

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

                ARFaceView(
                    onGazeUpdate: { point in
                        rawGazePoint = point
                        if emaInitialized {
                            emaRawPoint = CGPoint(
                                x: emaAlpha * point.x + (1 - emaAlpha) * emaRawPoint.x,
                                y: emaAlpha * point.y + (1 - emaAlpha) * emaRawPoint.y
                            )
                        } else {
                            emaRawPoint = point
                            emaInitialized = true
                        }
                        let calibrated = calibrator.apply(point)
                        calibratedPoint = calibrated
                        displayPoint = kalman.filter(measurement: calibrated)
                    },
                    onGazeDiagnostic: { h, v in
                        blendH = h
                        blendV = v
                    }
                )
                .allowsHitTesting(false)
                .opacity(0.001)

                // Overlay de diagnostic : trois points pour distinguer ce qui
                // sort d'ARKit (rouge), ce qui sort du calibrateur (jaune) et
                // ce que voit l'utilisateur (bleu, après Kalman). Si le point
                // rouge ne bouge pas quand on bouge les yeux → problème ARKit.
                // Si rouge bouge mais jaune pas → calibrateur. Si jaune bouge
                // mais bleu très lent → Kalman trop lissant.
                DiagnosticDot(color: .red,    diameter: 14).position(rawGazePoint).allowsHitTesting(false)
                DiagnosticDot(color: .yellow, diameter: 14).position(calibratedPoint).allowsHitTesting(false)
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

                    DiagnosticReadout(
                        raw: rawGazePoint,
                        calibrated: calibratedPoint,
                        smoothed: displayPoint,
                        canvas: geo.size,
                        scaleX: calibrator.m00,
                        scaleY: calibrator.m11,
                        blendH: blendH,
                        blendV: blendV
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
        guard emaInitialized, rawGazePoint != .zero else {
            withAnimation(.easeInOut(duration: 0.2)) { showRejectedFeedback = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.easeInOut(duration: 0.3)) { showRejectedFeedback = false }
            }
            return
        }
        // On utilise la moyenne mobile : un instantané a typiquement ±5–10 px
        // de bruit, ce qui détruit la pente de régression quand le signal raw
        // est lui-même petit (cas des enfants Rett avec amplitude oculaire
        // modeste). Moyennée sur ~100 ms, l'entrée est nettement plus propre.
        calibrator.addSample(raw: emaRawPoint, actual: target)
        showRejectedFeedback = false

        withAnimation(.easeOut(duration: 0.18)) { splashAtTarget = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            splashAtTarget = false
            withAnimation(.easeInOut(duration: 0.25)) {
                currentIndex = currentIndex + 1
            }
            // Reset EMA : la cible suivante implique un nouveau regard, on ne
            // veut pas que le sample suivant soit contaminé par l'historique
            // de la cible précédente.
            emaInitialized = false
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
    let scaleX: CGFloat
    let scaleY: CGFloat
    let blendH: CGFloat
    let blendV: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                // Affiche les valeurs brutes de face.lookAtPoint en mm pour
                // qu'on voie directement si ARKit fournit du signal sur
                // l'axe horizontal. Bouger les yeux gauche/droite DOIT
                // faire varier la valeur x ; si elle reste à zéro c'est
                // ARKit qui ne capte pas ce signal.
                Text(String(format: "lookAt x=%+6.1f y=%+6.1f mm",
                            Double(blendH) * 1000, Double(blendV) * 1000))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.85))
            row(color: .red,    label: "raw",  pt: raw)
            row(color: .yellow, label: "cal",  pt: calibrated)
            row(color: .blue,   label: "out",  pt: smoothed)
            HStack {
                Text("canvas \(Int(canvas.width))×\(Int(canvas.height))")
                Spacer()
                Text(String(format: "gain x=%.2f y=%.2f", Double(scaleX), Double(scaleY)))
            }
            .foregroundStyle(.white.opacity(0.6))
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
