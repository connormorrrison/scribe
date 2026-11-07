import SwiftUI

@main
struct ScribeApp: App {
    /// The landing shows on every cold launch, until the user swipes up.
    @State private var showLanding = true
    /// Turns true as the landing starts sliding away, so the content pops in underneath it.
    @State private var revealed = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(isRevealed: revealed)
                if showLanding {
                    // The landing slides itself away, then is removed.
                    LandingView(onLeave: { revealed = true }, onContinue: { showLanding = false })
                        .zIndex(1)
                }
            }
        }
    }
}
