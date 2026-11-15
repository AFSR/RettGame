import SwiftUI

@main
struct RettGameApp: App {
    init() {
        AFSRAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            GameRootView()
                .tint(.afsrPrimaryAdaptive)
                .foregroundStyle(Color.afsrText)
        }
    }
}
