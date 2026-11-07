import SwiftUI

/// The main app content. Placeholder until the main UI is built.
struct ContentView: View {
    /// False while the landing is on screen; the content pops in when it turns true.
    var isRevealed = true

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            Text("Hello, World")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .scaleEffect(isRevealed ? 1 : 0.85)
                .opacity(isRevealed ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.68).delay(0.15), value: isRevealed)
        }
    }
}

#Preview {
    ContentView()
}
