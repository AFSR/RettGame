import SwiftUI
import SwiftData
import ARKit

struct EyeGameView: View {
    @Query private var profiles: [ChildProfile]
    @State private var viewModel = EyeGameViewModel()

    private var profile: ChildProfile? { profiles.first }

    var body: some View {
        Group {
            if !viewModel.isEyeTrackingAvailable() {
                UnsupportedView()
            } else {
                switch viewModel.state {
                case .configuration:
                    ConfigurationView(viewModel: viewModel)
                case .playing:
                    PlayingView(viewModel: viewModel, childName: profile?.firstName ?? "")
                case .finished(let score, let total):
                    FinishedView(score: score, total: total, childName: profile?.firstName ?? "") {
                        viewModel.reset()
                    }
                }
            }
        }
        .navigationTitle("Jeu du Regard")
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
            Text("Le jeu de regard nécessite un iPhone X ou un iPad Pro avec caméra TrueDepth Face ID. Votre appareil n'est pas compatible.")
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
    @Bindable var viewModel: EyeGameViewModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Nombre de parties") {
                    Picker("Cibles", selection: $viewModel.targetCount) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("10").tag(10)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Vitesse") {
                    Picker("Vitesse", selection: $viewModel.speed) {
                        ForEach(GameSpeed.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Taille des cibles") {
                    Picker("Taille", selection: $viewModel.targetSize) {
                        ForEach(TargetSize.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Options") {
                    Toggle("Indicateur de regard", isOn: $viewModel.showGazeIndicator)
                    Toggle("Musique de fond", isOn: $viewModel.musicEnabled)
                }
                Section {
                    Text("Tenez l'appareil face à l'enfant, à 30-60 cm. L'enfant regarde le personnage pour lui envoyer une tarte à la crème 🥧.")
                        .font(AFSRFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            AFSRPrimaryButton(title: "Lancer la partie", icon: "play.fill") {
                viewModel.launchPlaying()
            }
            .padding()
            .background(Color(.systemBackground))
        }
    }
}

// MARK: - Playing

private struct PlayingView: View {
    @Bindable var viewModel: EyeGameViewModel
    let childName: String

    @State private var canvasSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.02).ignoresSafeArea()

                // Capture ARKit en arrière-plan (caméra masquée)
                ARFaceView { point in
                    viewModel.handleGaze(point, in: canvasSize)
                }
                .allowsHitTesting(false)
                .opacity(0.001)

                // Zone tactile pleine surface : un tap du parent = "l'enfant regarde ici".
                // Placée sous les visuels (qui sont non-interactifs) → reçoit tous les taps
                // hors des contrôles en haut.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(coordinateSpace: .local)
                            .onEnded { event in
                                viewModel.recordCalibrationTap(at: event.location, canvasSize: canvasSize)
                            }
                    )

                // Visuels non-interactifs (les taps les traversent)
                Group {
                    if let target = viewModel.currentTarget {
                        TargetView(target: target, progress: viewModel.processor.dwellProgress)
                            .position(target.position)
                            .animation(.easeInOut(duration: 0.35), value: target.position)
                    }
                    if let splash = viewModel.splashAt {
                        SplashView()
                            .position(splash)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if viewModel.showGazeIndicator {
                        Circle()
                            .fill(Color.afsrPurple.opacity(0.4))
                            .frame(width: 20, height: 20)
                            .position(viewModel.lastGazePoint)
                    }
                }
                .allowsHitTesting(false)

                VStack {
                    HStack {
                        Button("Quitter") { viewModel.reset() }
                            .buttonStyle(.borderedProminent)
                            .tint(.afsrPurpleAdaptive)
                        Spacer()
                        CalibrationBadge(count: viewModel.calibrator.samplesCount) {
                            viewModel.resetCalibration()
                        }
                        ScoreBadge(score: viewModel.score)
                    }
                    .padding()
                    Spacer()
                    Text("Touchez le personnage quand votre enfant le regarde — cela calibre le suivi du regard.")
                        .font(AFSRFont.caption())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
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

private struct TargetView: View {
    let target: GameTarget
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.afsrPurple.opacity(0.3), lineWidth: 6)
                .frame(width: target.diameter + 16, height: target.diameter + 16)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(Color.afsrPurple, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: target.diameter + 16, height: target.diameter + 16)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)

            Text("😄")
                .font(.system(size: target.diameter * 0.7))
                .frame(width: target.diameter, height: target.diameter)
        }
    }
}

private struct SplashView: View {
    @State private var scale: CGFloat = 0.2
    @State private var opacity: Double = 1
    var body: some View {
        Text("🥧")
            .font(.system(size: 220))
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    scale = 1.2
                }
                withAnimation(.easeOut(duration: 1.0).delay(0.3)) {
                    opacity = 0
                }
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

/// Badge indiquant le nombre de points de calibration enregistrés.
/// Long-press pour réinitialiser.
private struct CalibrationBadge: View {
    let count: Int
    let onReset: () -> Void

    @State private var showResetConfirm = false

    private var status: (icon: String, color: Color, label: String) {
        switch count {
        case 0:    return ("scope", .orange, "Non calibré")
        case 1:    return ("scope", .orange, "1 pt")
        case 2...4: return ("scope", .yellow, "\(count) pts")
        default:   return ("scope", .afsrSuccess, "\(count) pts")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Badge cliquable → menu
            Menu {
                Section("Calibration") {
                    Label(status.label, systemImage: status.icon)
                }
                Section {
                    Text("Touchez le personnage quand votre enfant le regarde pour calibrer le suivi du regard. Les points sont conservés entre les parties.")
                }
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Réinitialiser la calibration", systemImage: "arrow.counterclockwise")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: status.icon).foregroundStyle(status.color)
                    Text(status.label).font(AFSRFont.caption())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel("Calibration : \(status.label). Toucher pour les options.")

            // Bouton reset visible directement (en complément du menu, au cas où)
            Button {
                showResetConfirm = true
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.afsrEmergency.opacity(0.85))
                    .background(Circle().fill(Color.white.opacity(0.001))) // hit-area
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Réinitialiser la calibration du regard")
        }
        .confirmationDialog(
            "Réinitialiser la calibration ?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Réinitialiser", role: .destructive) { onReset() }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Tous les points de calibration enregistrés seront supprimés. Vous devrez retaper sur le personnage pour recalibrer le suivi du regard.")
        }
    }
}

// MARK: - Finished

private struct FinishedView: View {
    let score: Int
    let total: Int
    let childName: String
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("🎉")
                .font(.system(size: 120))
            Text(childName.isEmpty ? "Bravo !" : "Bravo \(childName) !")
                .font(AFSRFont.title(36))
            Text("Tu as visé \(score) fois sur \(total) !")
                .font(AFSRFont.headline())
                .foregroundStyle(.secondary)
            Spacer()
            AFSRPrimaryButton(title: "Rejouer", icon: "arrow.clockwise", action: onRestart)
                .padding(.horizontal)
            Spacer()
        }
    }
}

#Preview("Config") {
    NavigationStack { EyeGameView() }
        .modelContainer(PreviewData.container)
}
