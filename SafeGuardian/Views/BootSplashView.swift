import SwiftUI

/// Full-screen boot splash that continues the static launch screen frame:
/// the wordmark bursts into cipher glyphs, decrypts back character by
/// character left to right, blinks a block cursor, then hands off.
///
/// The first rendered frame is pixel-identical to LaunchScreen.storyboard
/// (Menlo 38pt, sRGB pure green on black, centered) so the transition from
/// the system launch snapshot into this live view is invisible.
struct BootSplashView: View {
    let onFinished: () -> Void

    private static let wordmark: [Character] = Array("SafeGuardian")
    private static let cipherGlyphs: [Character] = Array("!@#$%&*<>/\\|+=?~^;:0123456789ABCDEF")

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var display = String(BootSplashView.wordmark)
    @State private var cursorVisible = false

    var body: some View {
        ZStack {
            Color.black
            // Symmetric hidden leading block keeps the wordmark centered
            // exactly like the storyboard label while the trailing cursor
            // blinks without shifting layout.
            HStack(spacing: 0) {
                Text(verbatim: "\u{2588}").opacity(0)
                Text(verbatim: display)
                Text(verbatim: "\u{2588}").opacity(cursorVisible ? 1 : 0)
            }
            .font(.custom("Menlo", size: 38))
            .foregroundColor(Color(red: 0, green: 1, blue: 0))
            .lineLimit(1)
        }
        .ignoresSafeArea()
        .task { await run() }
    }

    private func run() async {
        if reduceMotion {
            try? await Task.sleep(nanoseconds: 600_000_000)
            onFinished()
            return
        }
        // Hold the storyboard-identical frame so the handoff is seamless.
        try? await Task.sleep(nanoseconds: 250_000_000)

        let word = Self.wordmark
        for locked in 0...word.count {
            // Two scramble ticks per locked character keeps unlocked
            // glyphs cycling while the decrypt front advances.
            for _ in 0..<2 {
                display = String(word[..<locked]) + randomCipher(count: word.count - locked)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        display = String(word)

        for _ in 0..<2 {
            cursorVisible = true
            try? await Task.sleep(nanoseconds: 220_000_000)
            cursorVisible = false
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        onFinished()
    }

    private func randomCipher(count: Int) -> String {
        String((0..<count).map { _ in Self.cipherGlyphs.randomElement() ?? "#" })
    }
}
