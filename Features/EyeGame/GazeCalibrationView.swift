import SwiftUI

/// Session de calibration guidée : 9 cibles successives sur une grille 3×3.
///
/// Le parent tient l'appareil face à l'enfant, attire son regard sur chaque
/// cible, et tape n'importe où à l'écran quand l'enfant la regarde. Chaque tap
/// enregistre une paire `(rawGaze courant, position cible)` dans le calibrateur.
struct GazeCalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: EyeGameViewModel

    private let normalizedPositions: [CGPoint] = [
        CGPoint(x: 0.15, y: 0.22), CGPoint(x: 0.50, y: 0.22), CGPoint(x: 0.85, y: 0.22),
        CGPoint(x: 0.15, y: 0.50), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.85, y: 0.50),
        CGPoint(x: 0.15, y: 0.78), CGPoint(x: 0.50, y: 0.78), CGPoint(x: 0.85, y: 0.78),
    ]

    @State private var currentIndex: Int = 0
    @State private var canvasSize: CGSize = .zero
    @State private var finished: Bool = false
    @State private var pulse: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                ARFaceView { point in
                    viewModel.rawGazePoint = point
                }
                .allowsHitTesting(false)
                .opacity(0.001)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleTap()
                    }

                if !finished, currentIndex < normalizedPositions.count {
                    let p = currentPosition(in: geo.size)
                    TargetDot(diameter: 110, pulsing: pulse)
                        .position(p)
                        .transition(.scale.combined(with: .opacity))
                        .id(currentIndex)
                }

                VStack {
                    HStack {
                        Button("Annuler") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .tint(.afsrPurpleAdaptive)
                        Spacer()
                        ProgressBadge(
                            current: min(currentIndex, normalizedPositions.count),
                            total: normalizedPositions.count
                        )
                    }
                    .padding()

                    Spacer()

                    if finished {
                        FinishedBanner()
                            .padding(.bottom, 40)
                    } else {
                        InstructionBanner()
                            .padding(.horizontal, 24)
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
        let n = normalizedPositions[currentIndex]
        return CGPoint(x: n.x * size.width, y: n.y * size.height)
    }

    private func handleTap() {
        guard !finished, currentIndex < normalizedPositions.count else { return }
        let target = currentPosition(in: canvasSize)
        // Ignore le tap si ARKit n'a pas encore fourni de regard valide :
        // mieux vaut redemander que d'enregistrer un (0,0) → cible.
        guard viewModel.recordCalibrationSample(actual: target) else { return }

        let next = currentIndex + 1
        if next >= normalizedPositions.count {
            withAnimation(.easeOut(duration: 0.3)) { finished = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                dismiss()
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { currentIndex = next }
        }
    }
}

private struct TargetDot: View {
    let diameter: CGFloat
    let pulsing: Bool

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
            Text("👀")
                .font(.system(size: diameter * 0.6))
        }
        .accessibilityLabel("Cible de calibration")
    }
}

private struct ProgressBadge: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope").foregroundStyle(.afsrPurpleLight)
            Text("\(current) / \(total)").font(AFSRFont.headline()).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
    }
}

private struct InstructionBanner: View {
    var body: some View {
        Text("Attirez le regard de votre enfant sur la cible, puis touchez l'écran quand il la regarde.")
            .font(AFSRFont.body())
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct FinishedBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("🎯")
                .font(.system(size: 64))
            Text("Calibration terminée")
                .font(AFSRFont.title(28))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
