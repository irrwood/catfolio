import SwiftUI

/// The presentation host owns the zoom geometry and interactive dismissal.
struct AIAssistantPage: View {
    @Environment(\.locale) private var appLocale

    /// A root tab: nothing to close back to, so no close control.
    var body: some View {
        AIView(isEmbedded: true, usesRootTabHeader: true, onClose: nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .homeTabBackground()
    }
}

/// The assistant's ground: opaque, so nothing of the page behind the zoom
/// shows through, in the reader's appearance.
enum AIConversationGround {
    static func base(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }
}

/// A stationary blue light below the conversation, on the dark page only;
/// the light page is plain white. Keep the base opaque and size the glow to
/// the screen, including the area behind the keyboard.
struct AIConversationGlowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 1.0 : 0
        GeometryReader { geometry in
            // Wider than the screen, centred on its bottom edge: half the
            // light is below the glass, and what shows is a broad rise.
            let diameter = min(geometry.size.width * 1.8, 820)

            Circle()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color(red: 0.08, green: 0.56, blue: 1).opacity(0.90 * strength), location: 0),
                            .init(color: Color(red: 0.035, green: 0.38, blue: 0.92).opacity(0.70 * strength), location: 0.3),
                            .init(color: Color(red: 0.02, green: 0.20, blue: 0.65).opacity(0.30 * strength), location: 0.6),
                            .init(color: .clear, location: 1),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )
                .frame(width: diameter, height: diameter)
                .blur(radius: diameter * 0.08)
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height
                )
        }
        .background(AIConversationGround.base(for: colorScheme))
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Both controls share keyboard state and fixed centres, so changing their
/// glass diameter never shifts either button or the conversation underneath.
struct AIConversationHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isKeyboardVisible = false
    let showsConversations: Bool
    let onToggleConversations: () -> Void
    let onNewConversation: () -> Void
    let onClose: (() -> Void)?

    private var diameter: CGFloat { isKeyboardVisible ? 56 : 48 }

    var body: some View {
        HStack {
            control(showsConversations ? Image(systemName: "chevron.down") : Image("AssistantMenu").renderingMode(.template),
                    action: onToggleConversations)
                .accessibilityLabel(L10n.text(showsConversations ? "回到对话" : "对话列表"))
            Spacer(minLength: 0)
            control(Image("AssistantCompose").renderingMode(.template), action: onNewConversation)
                .accessibilityLabel(L10n.text("新对话"))
                .accessibilityIdentifier("ai.conversations.new")
            if !showsConversations, let onClose {
                control("xmark", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.text("关闭 AI 投资助手"))
            }
        }
        .overlay {
            if showsConversations {
                Text(L10n.text("对话"))
                    .appText(.body, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isKeyboardVisible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onDisappear { isKeyboardVisible = false }
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        control(Image(systemName: symbol), action: action)
    }

    private func control(_ image: Image, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            image
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(CatfolioTheme.primaryText)
                .scaleEffect(isKeyboardVisible ? 1.1 : 1)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .modifier(AIHeaderGlass())
        }
        .buttonStyle(.plain)
        .frame(width: 56, height: 56)
    }
}

struct AIHeaderGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75)
                }
        }
    }
}

/// Keep scrolling messages behind the transparent toolbar. The lifted
/// conversation alone clips at its top corners when the history is shown.
struct AIConversationCardClip: Shape {
    var radius: CGFloat
    var topOverflow: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, topOverflow) }
        set { radius = newValue.first; topOverflow = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let expanded = CGRect(x: rect.minX, y: rect.minY - topOverflow,
                              width: rect.width, height: rect.height + topOverflow)
        return UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius,
                                      style: .continuous).path(in: expanded)
    }
}

/// Use the home's soft scroll edge so content dissolves under the toolbar
/// without an additional opaque white/black wash.
struct AIConversationTopEdge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.modifier(PortfolioTopScrollEdge(hasFloatingHeader: true))
        } else {
            content.overlay { AIConversationTopFade() }
        }
    }
}

struct AIConversationTopFade: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var topColor: Color {
        AIConversationGround.base(for: colorScheme)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if reduceTransparency {
                    LinearGradient(colors: [topColor, .clear], startPoint: .top, endPoint: .bottom)
                } else {
                    AIStatusBackdropBlur()
                }
            }
            .frame(height: max(62, geometry.safeAreaInsets.top) + 32)
            .offset(y: -geometry.safeAreaInsets.top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AIStatusBackdropBlur: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> BlurView { BlurView(scheme: colorScheme) }
    func updateUIView(_ view: BlurView, context: Context) { view.update(scheme: colorScheme) }

    final class BlurView: UIVisualEffectView {
        private let fadeMask = UIView()
        private let gradient = CAGradientLayer()
        private var maskBounds = CGRect.null
        private var scheme: ColorScheme

        init(scheme: ColorScheme = .light) {
            self.scheme = scheme
            // These blur styles tint towards white/black, without the adaptive
            // grey surface added by systemUltraThinMaterial.
            super.init(effect: UIBlurEffect(style: scheme == .dark ? .dark : .extraLight))
            isUserInteractionEnabled = false
            gradient.colors = [UIColor.black.cgColor, UIColor.black.cgColor,
                               UIColor.black.withAlphaComponent(0.65).cgColor,
                               UIColor.black.withAlphaComponent(0.20).cgColor, UIColor.clear.cgColor]
            gradient.locations = [0, 0.35, 0.60, 0.82, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            fadeMask.layer.addSublayer(gradient)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func update(scheme: ColorScheme) {
            guard self.scheme != scheme else { return }
            self.scheme = scheme
            effect = UIBlurEffect(style: scheme == .dark ? .dark : .extraLight)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds != maskBounds else { return }
            maskBounds = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fadeMask.frame = bounds
            gradient.frame = fadeMask.bounds
            // Mask the effect view itself; masking an ancestor breaks UIKit's
            // sampling of the messages scrolling behind this layer.
            mask = fadeMask
            CATransaction.commit()
        }
    }
}

extension View {
    @ViewBuilder
    func floatingGlassSurface<S: Shape>(in shape: S, tint: Color? = nil, isInteractive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(.regular.tint(tint).interactive(isInteractive), in: shape)
            } else {
                glassEffect(.regular.interactive(isInteractive), in: shape)
            }
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.16), lineWidth: 0.75)
                }
        }
    }
}

// MARK: - Streaming answer
