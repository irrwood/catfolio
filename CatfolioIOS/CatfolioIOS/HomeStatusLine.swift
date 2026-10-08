import SwiftUI
import UIKit

/// What the home page has to say, said in the line above its total rather
/// than in a toast: CATFOLIO at rest; while a refresh runs, that it is
/// running; and for a moment after, its result, or the note a tap on the
/// figures left.
@MainActor @Observable
final class HomeStatusLine {
    static let shared = HomeStatusLine()

    struct Message: Equatable {
        let text: String
        let kind: AppToast.Kind
    }

    private(set) var message: Message?
    private(set) var isRefreshing = false
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    /// Held as long as a toast with the same words would be.
    func show(_ text: String, kind: AppToast.Kind = .info, announcement: String? = nil) {
        clearTask?.cancel()
        message = Message(text: text, kind: kind)
        UIAccessibility.post(notification: .announcement, argument: announcement ?? text)
        playHaptic(kind)
        let hold = Duration.milliseconds(1600 + min(1400, text.count * 60))
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func beginRefresh() {
        clearTask?.cancel()
        message = nil
        isRefreshing = true
    }

    func endRefresh() { isRefreshing = false }

    private func playHaptic(_ kind: AppToast.Kind) {
        guard UserDefaults.standard.object(forKey: ChartInteractionStyle.hapticsPreferenceKey) as? Bool ?? true else { return }
        switch kind {
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .info: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

/// Replaces one line with another the way a toast's words come and go: the
/// old words draw back through a blur, right to left, and the new ones come
/// through it, left to right. `sweeps` decides which changes animate; the
/// rest swap at once.
struct SweepReplace<Value: Equatable, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    var sweeps: (Value, Value) -> Bool = { _, _ in true }
    @ViewBuilder let content: (Value) -> Content

    @State private var shown: Value?
    @State private var reveal: CGFloat = 1
    /// Bumped on every change, so a sweep that a newer change overtook
    /// does not finish with stale words.
    @State private var generation = 0

    private static var softEdge: CGFloat { 36 }

    var body: some View {
        content(shown ?? value)
            .blur(radius: (1 - reveal) * 6)
            .mask(alignment: .leading) { revealMask }
            .onAppear { if shown == nil { shown = value } }
            .onChange(of: value) { _, new in
                generation &+= 1
                let current = generation
                Task { await replace(with: new, generation: current) }
            }
    }

    private var revealMask: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle().frame(width: geometry.size.width)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.softEdge)
            }
            .offset(x: (geometry.size.width + Self.softEdge) * (reveal - 1))
        }
    }

    private func replace(with new: Value, generation current: Int) async {
        guard let old = shown else { shown = new; return }
        // Back to the words already shown, perhaps half swept out: bring
        // them back rather than leave the line empty.
        guard new != old else {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55)) { reveal = 1 }
            return
        }
        guard !reduceMotion, sweeps(old, new) else {
            shown = new
            reveal = 1
            return
        }
        withAnimation(.easeIn(duration: 0.2)) { reveal = 0 }
        try? await Task.sleep(for: .milliseconds(200))
        guard generation == current else { return }
        shown = new
        withAnimation(.easeOut(duration: 0.55)) { reveal = 1 }
    }
}
