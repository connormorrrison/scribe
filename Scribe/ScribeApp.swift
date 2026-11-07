import SwiftUI

@main
struct ScribeApp: App {
    @State private var store = CanvasStore()
    /// The landing shows on every launch, until the user swipes up.
    @State private var showLanding = true
    /// Turns true as the landing starts sliding away, so the content pops in underneath it.
    @State private var revealed = false
    @AppStorage(AppSettings.appearance) private var appearance = Appearance.system

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
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}
