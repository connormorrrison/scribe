import SwiftUI

/// The main app content: the library dashboard.
struct ContentView: View {
    let store: CanvasStore
    /// False while the landing is on screen; the content pops in when it turns true.
    var isRevealed = true

    var body: some View {
        LibraryView(store: store)
            .scaleEffect(isRevealed ? 1 : 0.96)
            .opacity(isRevealed ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: isRevealed)
    }
}

#Preview {
    ContentView(store: CanvasStore(directory: nil))
}
