import SwiftUI
import ARKit

/// Déclinaison native du jeu "Bulles colorées" de GazePlay : des bulles
/// montent depuis le bas, l'enfant les fait éclater en les regardant. La
/// pipeline gaze (ARKit → calibrator → Kalman → dwell) est partagée avec
/// les autres jeux via la persistance UserDefaults du calibrateur.
struct BubblesGameView: View {
    @AppStorage("childFirstName") private var childFirstName: String = ""
    @State private var viewModel = BubblesGameViewModel()

    var body: some View {
        Group {
            if !viewModel.isEyeTrackingAvailable() {
                UnsupportedView()
            } else {
                switch viewModel.state {
                case .configuration:
                    ConfigurationView(viewModel: viewModel)
                case .playing:
                    PlayingView(viewModel: viewModel, childName: childFirstName)
                case .finished(let score):
                    FinishedView(score: score, childName: childFirstName) {
                        viewModel.reset()
                    }
                }
            }
        }
        .navigationTitle("Bulles colorées")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Unsupported

private struct UnsupportedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash")
                .font(.system(size: 56))
                .foregroundStyle(.afsrPurpleLight)
            Text("Appareil non compatible")
                .font(AFSRFont.headline())
            Text("Ce jeu nécessite un iPhone X ou un iPad Pro avec caméra TrueDepth Face ID.")
                .font(AFSRFont.body())
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
        }
        .padding()
    }
}

// MARK: - Configuration

private struct ConfigurationView: View {
    @Bindable var viewModel: BubblesGameViewModel
    @State private var showCalibration = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    CalibrationRow(
                        sampleCount: viewModel.calibrator.samplesCount,
                        isCalibrated: viewModel.hasCalibration,
                        onCalibrate: { showCalibration = true }
                    )
                } header: {
                    Text("Calibration du regard")
                } footer: {
                    if !viewModel.hasCalibration {
                        Text("Une calibration est nécessaire avant de jouer.")
                            .foregroundStyle(.afsrEmergency)
                    }
                }
                Section("Durée") {
                    Picker("Durée", selection: $viewModel.duration) {
                        ForEach(BubbleDuration.allCases) { d in Text(d.label).tag(d) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Vitesse") {
                    Picker("Vitesse", selection: $viewModel.speed) {
                        ForEach(BubbleSpeed.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Taille des bulles") {
                    Picker("Taille", selection: $viewModel.bubbleSize) {
                        ForEach(TargetSize.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Options") {
                    Toggle("Indicateur de regard", isOn: $viewModel.showGazeIndicator)
                }
                Section {
                    Text("Les bulles montent depuis le bas. Votre enfant les fait éclater en les regardant 🫧.")
                        .font(AFSRFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            AFSRPrimaryButton(title: "Lancer la partie", icon: "play.fill") {
                viewModel.launchPlaying()
            }
            .disabled(!viewModel.hasCalibration)
            .opacity(viewModel.hasCalibration ? 1 : 0.5)
            .padding()
            .background(Color(.systemBackground))
        }
        .fullScreenCover(isPresented: $showCalibration) {
            GazeCalibrationView()
        }
    }
}

private struct CalibrationRow: View {
    let sampleCount: Int
    let isCalibrated: Bool
    let onCalibrate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCalibrated ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(isCalibrated ? Color.afsrSuccess : Color.afsrEmergency)
            VStack(alignment: .leading, spacing: 2) {
                Text(isCalibrated ? "Calibré" : "Non calibré")
                    .font(AFSRFont.headline())
                Text("\(sampleCount) point\(sampleCount > 1 ? "s" : "") enregistré\(sampleCount > 1 ? "s" : "")")
                    .font(AFSRFont.caption())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isCalibrated ? "Recalibrer" : "Calibrer", action: onCalibrate)
                .buttonStyle(.borderedProminent)
                .tint(.afsrPurpleAdaptive)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Playing

private struct PlayingView: View {
    @Bindable var viewModel: BubblesGameViewModel
    let childName: String

    @State private var canvasSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Color(hex: "#0B1B3A"), Color(hex: "#1F3D7A")],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ARFaceView { point in
                    viewModel.handleGaze(point, in: canvasSize)
                }
                .allowsHitTesting(false)
                .opacity(0.001)

                // Tap parent → calibration (et pop si la bulle est sous le doigt).
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(coordinateSpace: .local)
                            .onEnded { event in
                                viewModel.recordCalibrationTap(at: event.location, canvasSize: canvasSize)
                            }
                    )

                // Bulles — non interactives, le pop passe par le dwell ou
                // via le tap parent au-dessus.
                ForEach(viewModel.bubbles) { bubble in
                    BubbleView(
                        bubble: bubble,
                        progress: viewModel.processor.currentTargetId == bubble.id
                            ? viewModel.processor.dwellProgress
                            : 0
                    )
                    .position(bubble.position)
                    .transition(.scale.combined(with: .opacity))
                }
                .allowsHitTesting(false)

                if let splash = viewModel.splashAt {
                    PopSplash()
                        .position(splash)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                if viewModel.showGazeIndicator {
                    Circle()
                        .fill(Color.blue.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                        .shadow(color: .blue.opacity(0.5), radius: 6)
                        .position(viewModel.lastGazePoint)
                        .allowsHitTesting(false)
                }

                VStack {
                    HStack {
                        Button("Quitter") { viewModel.reset() }
                            .buttonStyle(.borderedProminent)
                            .tint(.afsrPurpleAdaptive)
                        Spacer()
                        TimerBadge(remaining: viewModel.timeRemaining)
                        ScoreBadge(score: viewModel.score)
                    }
                    .padding()
                    Spacer()
                }
                .allowsHitTesting(true)
            }
            .onAppear {
                canvasSize = geo.size
                viewModel.applyStoredFilterSettings()
                viewModel.start(in: geo.size)
                #if targetEnvironment(simulator)
                viewModel.startMockGaze(canvasSize: geo.size)
                #endif
            }
            .onDisappear {
                #if targetEnvironment(simulator)
                viewModel.stopMockGaze()
                #endif
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
            }
        }
    }
}

private struct BubbleView: View {
    let bubble: Bubble
    let progress: Double

    var body: some View {
        let color = BubblesPalette.color(at: bubble.colorIndex)
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.95), color.opacity(0.55)],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: bubble.diameter
                    )
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(0.6), lineWidth: 2)
                )
                .frame(width: bubble.diameter, height: bubble.diameter)
                .shadow(color: color.opacity(0.5), radius: 6)

            // Highlight pour effet "bulle".
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: bubble.diameter * 0.25, height: bubble.diameter * 0.25)
                .offset(x: -bubble.diameter * 0.18, y: -bubble.diameter * 0.18)

            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: bubble.diameter + 14, height: bubble.diameter + 14)
                .animation(.linear(duration: 0.1), value: progress)
        }
    }
}

private struct PopSplash: View {
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 1

    var body: some View {
        Text("✨")
            .font(.system(size: 100))
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { scale = 1.4 }
                withAnimation(.easeOut(duration: 0.7).delay(0.1)) { opacity = 0 }
            }
    }
}

private struct ScoreBadge: View {
    let score: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
            Text("\(score)").font(AFSRFont.headline())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct TimerBadge: View {
    let remaining: TimeInterval
    private var formatted: String {
        let total = max(0, Int(remaining.rounded(.up)))
        let m = total / 60
        let s = total % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : "\(s)s"
    }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").foregroundStyle(.afsrPurpleLight)
            Text(formatted).font(AFSRFont.headline()).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Finished

private struct FinishedView: View {
    let score: Int
    let childName: String
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("🫧")
                .font(.system(size: 120))
            Text(childName.isEmpty ? "Bravo !" : "Bravo \(childName) !")
                .font(AFSRFont.title(36))
            Text("Tu as fait éclater \(score) bulle\(score > 1 ? "s" : "") !")
                .font(AFSRFont.headline())
                .foregroundStyle(.secondary)
            Spacer()
            AFSRPrimaryButton(title: "Rejouer", icon: "arrow.clockwise", action: onRestart)
                .padding(.horizontal)
            Spacer()
        }
    }
}
