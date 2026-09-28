import SwiftUI
import UIKit

/// A short confirmation: a few words, never a sentence. Detail belongs on the
/// page that produced it; the toast only says what just happened.
struct AppToast: Identifiable, Equatable {
    enum Kind { case success, info, error }
    let id = UUID()
    let message: String
    let kind: Kind
}

/// Shows one toast at a time, above every tab and sheet. A new toast replaces
/// the one on screen rather than queueing behind it.
@MainActor @Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var current: AppToast?
    @ObservationIgnored private var window: ToastWindow?

    func show(_ message: String, kind: AppToast.Kind = .success) {
        installWindowIfNeeded()
        current = AppToast(message: message, kind: kind)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func finish(_ id: UUID) {
        if current?.id == id { current = nil }
    }

    /// Its own window, so a sheet presented over the tabs does not cover it.
    /// It takes no touches: everything under it stays usable.
    private func installWindowIfNeeded() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        // Follow the app's own appearance setting, which can differ from the
        // system's.
        let style = scene.windows.first(where: \.isKeyWindow)?.traitCollection.userInterfaceStyle ?? .unspecified
        if let window, window.windowScene === scene {
            window.overrideUserInterfaceStyle = style
            return
        }
        let window = ToastWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: ToastHost(center: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

private final class ToastWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private struct ToastHost: View {
    let center: ToastCenter

    var body: some View {
        GeometryReader { geometry in
            VStack {
                if let toast = center.current {
                    ToastBubble(toast: toast, maximumWidth: max(44, geometry.size.width - 32)) { center.finish(toast.id) }
                        .id(toast.id)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
        }
        .fontDesign(.rounded)
    }
}

/// A circle scales up, opens sideways into a capsule, then the words come
/// through a blur from left to right; leaving, the same in reverse.
struct ToastBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let toast: AppToast
    let maximumWidth: CGFloat
    let onFinish: () -> Void

    @State private var isShown = false
    @State private var isExpanded = false
    @State private var reveal: CGFloat = 0
    @State private var expandedWidth: CGFloat = Self.diameter
    @State private var expandedHeight: CGFloat = Self.diameter

    private static let diameter: CGFloat = 44
    private static let textSoftEdge: CGFloat = 36

    private var symbol: String {
        switch toast.kind {
        case .success: "checkmark"
        case .info: "info"
        case .error: "exclamationmark"
        }
    }

    private var symbolColor: Color {
        toast.kind == .error ? CatfolioTheme.danger : CatfolioTheme.primaryText
    }

    /// Long enough to read, short enough not to linger.
    private var hold: Duration {
        .milliseconds(1600 + min(1400, toast.message.count * 60))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            messageContent(wrapped: false)
            messageContent(wrapped: true)
        }
        .frame(width: maximumWidth, alignment: .leading)
        .fixedSize()
        .frame(width: isExpanded ? expandedWidth : Self.diameter,
               height: isExpanded ? expandedHeight : Self.diameter, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Self.diameter / 2))
        .modifier(ToastSurface())
        .scaleEffect(isShown ? 1 : 0.3)
        .opacity(isShown ? 1 : 0)
        .accessibilityHidden(true)
        .task { await run() }
    }

    private func messageContent(wrapped: Bool) -> some View {
        // The glyph sits centred in the circle's 44pt; the words tuck 8pt into
        // that slot so they read with the glyph, not beside an empty margin.
        HStack(spacing: -8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(symbolColor)
                .frame(width: Self.diameter, height: Self.diameter)
            Text(toast.message)
                .appText(.subheading, weight: .medium)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(wrapped ? nil : 1)
                .fixedSize(horizontal: !wrapped, vertical: true)
                .blur(radius: (1 - reveal) * 6)
                .mask(alignment: .leading) { revealMask }
                .padding(.trailing, 18)
                .padding(.vertical, 12)
        }
        .frame(width: wrapped ? maximumWidth : nil)
        .fixedSize(horizontal: !wrapped, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            expandedWidth = $0.width
            expandedHeight = max(Self.diameter, $0.height)
        }
    }

    /// Solid up to the reveal line, then a soft edge, then nothing: the line
    /// sweeps left to right as `reveal` goes from 0 to 1.
    private var revealMask: some View {
        GeometryReader { geometry in
            let soft = Self.textSoftEdge
            HStack(spacing: 0) {
                Rectangle().frame(width: geometry.size.width)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: soft)
            }
            .offset(x: (geometry.size.width + soft) * (reveal - 1))
        }
    }

    private func run() async {
        playHaptic()
        if reduceMotion {
            isExpanded = true
            reveal = 1
            withAnimation(.easeOut(duration: 0.2)) { isShown = true }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { isShown = false }
            try? await Task.sleep(for: .milliseconds(220))
            onFinish()
            return
        }
        withAnimation(.spring(duration: 0.35, bounce: 0.35)) { isShown = true }
        guard await pause(.milliseconds(220)) else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.18)) { isExpanded = true }
        guard await pause(.milliseconds(150)) else { return }
        withAnimation(.easeOut(duration: 0.55)) { reveal = 1 }
        guard await pause(hold) else { return }
        withAnimation(.easeIn(duration: 0.2)) { reveal = 0 }
        guard await pause(.milliseconds(140)) else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0)) { isExpanded = false }
        guard await pause(.milliseconds(220)) else { return }
        withAnimation(.easeIn(duration: 0.18)) { isShown = false }
        guard await pause(.milliseconds(200)) else { return }
        onFinish()
    }

    /// False once a newer toast has replaced this one.
    private func pause(_ duration: Duration) async -> Bool {
        try? await Task.sleep(for: duration)
        return !Task.isCancelled
    }

    private func playHaptic() {
        guard hapticsEnabled else { return }
        switch toast.kind {
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .info: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

private struct ToastSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let shape = RoundedRectangle(cornerRadius: 22)

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            // Tinted towards the page colour: clear glass let a navigation
            // title under the toast read through its words.
            content.glassEffect(.regular.tint(Color(uiColor: .systemBackground).opacity(0.6)), in: shape)
        } else {
            content
                .background(reduceTransparency ? AnyShapeStyle(SettingsTemplate.card) : AnyShapeStyle(.regularMaterial),
                            in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
        }
    }
}
