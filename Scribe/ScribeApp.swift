import SwiftUI

@main
struct ScribeApp: App {
    @State private var store = CanvasStore()
    /// The landing shows on launch (unless turned off in Settings), until the user swipes up.
    @State private var showLanding: Bool
    /// Turns true as the landing starts sliding away, so the content pops in underneath it.
    @State private var revealed: Bool

    init() {
        let intro = UserDefaults.standard.object(forKey: AppSettings.showIntro) as? Bool ?? true
        _showLanding = State(initialValue: intro)
        _revealed = State(initialValue: !intro)

    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(store: store, isRevealed: revealed)
                if showLanding {
                    // The landing slides itself away, then is removed.
                    LandingView(onLeave: { revealed = true }, onContinue: { showLanding = false })
                        .zIndex(1)
                }
            }
            .fontDesign(.rounded)
        }
    }
}
