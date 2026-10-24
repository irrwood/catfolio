import SwiftUI
import UIKit
import Observation

enum HoldingDetailCardStyle {
    static let pageInset: CGFloat = 16
    static let contentInset: CGFloat = 20
    static let spacing: CGFloat = 16
    static let cornerRadius: CGFloat = 24
    static let minimumRowHeight: CGFloat = 105
}

/// Every child modal of a security uses the same native leading close button.
struct HoldingDetailCloseToolbar: ToolbarContent {
    @Environment(\.isWorkspaceDetail) private var isWorkspaceDetail
    let action: () -> Void

    var body: some ToolbarContent {
        if !isWorkspaceDetail {
            ToolbarItem(placement: .topBarLeading) {
                Button(L10n.text("关闭弹窗"), systemImage: "xmark", action: action)
                    .labelStyle(.iconOnly)
                    .tint(CatfolioTheme.primaryText)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("holding-modal-close")
            }
        }
    }
}

/// Shared label for the Financial and AI entry cards. The caller owns the
/// button action and presentation; the label owns only appearance.
struct HoldingDetailActionCardLabel: View {
    let title: String
    let subtitle: String
    var symbol: String? = "chevron.right"
    var isLoading = false

    var body: some View {
        HoldingDetailCardHeader(title: title, subtitle: subtitle, symbol: symbol, isLoading: isLoading)
            .contentShape(RoundedRectangle(cornerRadius: HoldingDetailCardStyle.cornerRadius, style: .continuous))
            .holdingDetailCard()
    }
}

/// A research entry keeps a fixed place in the holding page. Its content
/// opens in the same independent child-page presentation as Financial.
struct HoldingDetailChildPageCard<Content: View>: View {
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let title: String
    let subtitle: String
    @Binding var isPresented: Bool
    var isLoading = false
    var isEnabled = true
    var onDismiss: () -> Void = {}
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button { isPresented = true } label: {
            HoldingDetailActionCardLabel(title: title, subtitle: subtitle, isLoading: isLoading)
        }
        .buttonStyle(PanelPressButtonStyle())
        .disabled(!isEnabled)
        .workspacePage(isPresented: $isPresented, onDismiss: onDismiss) {
            HoldingDetailChildPage(title: title, content: content)
        }
        .sensoryFeedback(.selection, trigger: isPresented) { _, presented in hapticsEnabled && presented }
    }
}

struct HoldingDetailChildPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        DetailPageNavigation {
            SettingsPage(bottomInset: 24, topInset: SettingsTemplate.sectionSpacing) {
                HoldingDetailChildPageContent(content: content)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                HoldingDetailCloseToolbar { dismiss() }
            }
            .accessibilityIdentifier("holding-research-child-page")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// Shared content surface, also used when checking a child page's layout.
struct HoldingDetailChildPageContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoldingDetailCardStyle.contentInset)
            .holdingDetailCard()
    }
}

/// Title and secondary line, set the same way on every research card —
/// action, disclosure, and the prediction markets card alike.
struct HoldingDetailCardTitle: View {
    let title: String
    /// A card with nothing to add under its name leaves this out.
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appText(.subheading, weight: .medium)
                .foregroundStyle(CatfolioTheme.primaryText)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .appText(.label, weight: .medium)
                    .foregroundStyle(.primary.opacity(0.50))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The row the action card and the disclosure card are both made of.
struct HoldingDetailCardHeader: View {
    let title: String
    let subtitle: String
    var symbol: String?
    var isLoading = false
    var symbolRotation: Angle = .zero

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HoldingDetailCardTitle(title: title, subtitle: subtitle)

            if isLoading {
                ChartSkeletonShape(width: 12, height: 12, cornerRadius: 6).frame(width: 16, height: 24).chartLoadingShimmer()
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(symbolRotation)
                    .frame(width: 16, height: 24)
                    .accessibilityHidden(true)
            }
        }
        .padding(HoldingDetailCardStyle.contentInset)
        .frame(maxWidth: .infinity, minHeight: HoldingDetailCardStyle.minimumRowHeight, alignment: .leading)
    }
}

/// A plain card: the settings card's fill, no shadow or glass, so the
/// sheet's ground does not show through as a gradient in tall cards. By day
/// card and sheet are both white, so a 5% black hairline marks the edge.
struct HoldingDetailCardModifier: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HoldingDetailCardStyle.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(SettingsTemplate.card, in: shape)
            // The standard cell's outline, 5% of the ink in either appearance.
            .overlay {
                shape.strokeBorder(SettingsTemplate.cardBorder, lineWidth: SettingsTemplate.cardBorderWidth)
                    .allowsHitTesting(false)
            }
    }
}

/// Volume Profile and 52-Week Range share the cap-height heading from
/// Figma 610:15521, with 24pt above it and 20pt before the plot.
struct HoldingDetailSectionCard<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    /// The card's figures for a long-press explanation; nil offers none.
    var insightFacts: (() -> String?)?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .appText(.heading, weight: .medium, trimsLeading: true)
                        .foregroundStyle(CatfolioTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .appText(.label, weight: .medium)
                            .foregroundStyle(.primary.opacity(0.50))
                    }
                }
                .securityCardInsight(title: title, facts: insightFacts)
                Spacer(minLength: 0)
                trailing()
                    .appNumber(.body, weight: .medium, trimsLeading: true)
                    .foregroundStyle(.primary.opacity(0.30))
                    .fixedSize()
            }
            content()
        }
        .padding([.horizontal, .bottom], HoldingDetailCardStyle.contentInset)
        .padding(.top, 24)
        .padding(SettingsTemplate.cardBorderWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holdingDetailCard()
    }
}

extension HoldingDetailSectionCard where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, insightFacts: (() -> String?)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, insightFacts: insightFacts,
                  trailing: { EmptyView() }, content: content)
    }
}

/// Asks the page to explain a card: its title, its figures, and where the
/// title is on screen for the paper to grow out of.
struct SecurityCardInsightAction {
    let present: (_ title: String, _ facts: String, _ source: CGRect) -> Void

    func callAsFunction(title: String, facts: String, source: CGRect) {
        present(title, facts, source)
    }
}

extension EnvironmentValues {
    @Entry var securityCardInsight: SecurityCardInsightAction? = nil
}

/// A long press on a card's title opens the AI's reading of that card, in
/// the "今天有什么动静？" paper. The figures are read at the press, not
/// before, so nothing is formatted while the page scrolls.
struct SecurityCardInsightPress: ViewModifier {
    private final class FrameBox { var frame: CGRect = .zero }

    @Environment(\.securityCardInsight) private var insight
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let title: String
    let facts: (() -> String?)?
    @State private var box = FrameBox()
    @State private var pressCount = 0

    func body(content: Content) -> some View {
        if let insight, let facts {
            content
                .contentShape(Rectangle())
                // Kept in a box, not state: the frame changes on every scroll
                // frame and nothing needs to redraw for it.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.frame = $0 }
                .onLongPressGesture(minimumDuration: 0.45) {
                    guard let text = facts(), !text.isEmpty else { return }
                    pressCount += 1
                    insight(title: title, facts: text, source: box.frame)
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: pressCount) { _, _ in hapticsEnabled }
                .accessibilityAction(named: Text(L10n.text("AI 解读"))) {
                    guard let text = facts(), !text.isEmpty else { return }
                    insight(title: title, facts: text, source: box.frame)
                }
                .accessibilityHint(L10n.text("长按标题查看 AI 解读"))
                #if DEBUG
                // Fires the first card's long press, for recording the paper.
                .task {
                    guard LaunchArguments.contains("--demo-card-insight"),
                          !SecurityCardInsightDemo.fired else { return }
                    try? await Task.sleep(for: .seconds(3))
                    guard !SecurityCardInsightDemo.fired, let text = facts(), !text.isEmpty else { return }
                    SecurityCardInsightDemo.fired = true
                    insight(title: title, facts: text, source: box.frame)
                }
                #endif
        } else {
            content
        }
    }
}

extension View {
    /// Offers an AI explanation of the card this title heads, from `facts`.
    func securityCardInsight(title: String, facts: (() -> String?)?) -> some View {
        modifier(SecurityCardInsightPress(title: title, facts: facts))
    }
}

struct SecurityCardInsightRequest: Identifiable {
    let id = UUID()
    let context: SecurityCardInsightContext
    let sourceFrame: CGRect
}

/// One shell for the holding detail's research entries and expanded cards.
/// Keep fill and radius shared across every section and state.
extension View {
    func holdingDetailCard() -> some View {
        modifier(HoldingDetailCardModifier())
    }
}
