import SwiftUI
import UIKit

/// The settings template, taken from the Figma page `设置`
/// (`EtNSXmasS8lz9JzrWUoMd9`, node `241:42198`).
///
/// Every settings screen — the tab itself and each page it pushes — is built
/// from the pieces in this file, so a spacing or colour decision is made once
/// here rather than re-guessed per screen.
///
/// The design was drawn by editing Apple's own Figma components, so the code
/// does the same: the rows below wrap `NavigationLink`, `Button`, `Toggle` and
/// `Menu` and restyle them. Nothing here reimplements a control's behaviour,
/// which is why press highlighting, VoiceOver, Dynamic Type and the menu's own
/// presentation still come from the system.
enum SettingsTemplate {
    // MARK: Layout

    /// Page edge. The cards start here; the large navigation title above them
    /// keeps the system's own inset.
    static let pageInset: CGFloat = 16
    /// Scrollable breathing room above the floating controls on root tabs.
    static let rootTabBottomInset: CGFloat = 96
    /// The single vertical rhythm of the page: title to card, header to card,
    /// card to the next header.
    static let sectionSpacing: CGFloat = 16
    /// A section header carries this above itself, on top of the page gap, so
    /// a new section opens on 32 while its own card stays 16 below the header
    /// that names it. One value, not two gaps to keep in step.
    static let sectionHeaderTopSpacing: CGFloat = 16
    /// A note belongs to the card above it, so it sits closer than a new
    /// section would — 10, not the page's 16.
    static let footnoteTopSpacing: CGFloat = 10
    static let cardRadius: CGFloat = 24

    /// Row padding. Everything is set from the padding rather than a fixed
    /// height, so a row still looks like the drawing when the reader turns
    /// their text size up.
    static let rowHorizontalPadding: CGFloat = 20
    static let rowVerticalPadding: CGFloat = 16
    /// Only a floor, for the rows whose content does not reach it. Everything
    /// taller comes out of the padding plus the text, which is why a two-line
    /// row lands on 72 and keeps its proportions when the reader turns their
    /// text size up.
    static let rowMinHeight: CGFloat = 60

    /// Icon artboard. 24×24, and the icon is drawn to fill it rather than
    /// being set inside a tinted tile.
    static let iconSize: CGFloat = 24
    /// Icon to text.
    static let iconSpacing: CGFloat = 12
    /// Title to subtitle inside a stacked row.
    static let subtitleSpacing: CGFloat = 4
    /// A trailing value to the caret that opens its menu.
    static let valueSpacing: CGFloat = 6

    static let chevronSize = CGSize(width: 5, height: 10)
    static let caretSize = CGSize(width: 8, height: 5)

    /// The chip row under the title. A chip is 37 tall on 20/12 padding and
    /// rounded past half its own height, so it is a capsule; chips sit flush
    /// against each other and the row itself is inset on the page edge.
    static let segmentHeight: CGFloat = 37
    static let segmentHorizontalPadding: CGFloat = 20
    static let segmentVerticalPadding: CGFloat = 12
    static let segmentBarVerticalPadding: CGFloat = 10

    /// The gutter in a grid of tiles, between columns and between rows alike.
    /// Tighter than the page's own 16: tiles in a grid are one group being
    /// read together, and the section rhythm sets them too far apart to read
    /// as one.
    static let tileSpacing: CGFloat = 12

    /// The bar's own height, from the chip and the padding around it rather
    /// than a number typed twice. The chip grows past 37 when the reader turns
    /// their text size up, and the bar grows with it.
    static func segmentBarHeight(forLineHeight lineHeight: CGFloat) -> CGFloat {
        segmentBarVerticalPadding * 2
            + max(segmentHeight, lineHeight + segmentVerticalPadding * 2)
    }

    /// An unselected chip's label fading to a selected one's as the pages
    /// slide. `weight` is 0 for a chip fully off screen-centre and 1 for the
    /// chip the reader has landed on.
    static func segmentTitleColor(weight: CGFloat) -> UIColor {
        UIColor { trait in
            let from = uiSecondaryText.resolvedColor(with: trait)
            let to = UIColor.label.resolvedColor(with: trait)
            var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
            var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
            from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
            to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            let w = min(1, max(0, weight))
            return UIColor(
                red: fr + (tr - fr) * w,
                green: fg + (tg - fg) * w,
                blue: fb + (tb - fb) * w,
                alpha: fa + (ta - fa) * w
            )
        }
    }

    /// The note under a card: inset past the card's own rounded corners so it
    /// sits under the text column, not under the card edge.
    static let footnoteInset: CGFloat = 20
    /// 12pt set on 1.4 — the drawing's two lines measure 34pt together.
    static let footnoteLineSpacing: CGFloat = 2.5

    // MARK: Colour

    /// Every colour is defined once, as a dynamic `UIColor`, and handed to
    /// SwiftUI as a `Color` beside it.
    ///
    /// Two reasons for the shape. A dynamic colour resolves its own light and
    /// dark values from the trait environment, so no view has to hold a
    /// `ColorScheme` just to ask for a fill. And the History category bar is a
    /// `UIView` — it needs the same greys as the rows above it, and this is
    /// what keeps it from carrying a second copy of them.

    /// `#EEEFEF`. Not `systemGroupedBackground`: that is `#F2F2F7`, a colder
    /// grey. This one is a shade deeper than the near-white it started at, so
    /// the white cards read as lifted off it rather than floating in fog.
    static let uiPageBackground = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? .black
            : UIColor(red: 0xEE / 255, green: 0xEF / 255, blue: 0xEF / 255, alpha: 1)
    }
    static let pageBackground = Color(uiColor: uiPageBackground)

    /// The card fill: white, and the system's own grouped-row grey in the dark.
    /// Also the selected chip in the category bar, which is a card the size of
    /// a word.
    static let uiCard = UIColor { trait in
        trait.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white
    }
    static let card = Color(uiColor: uiCard)

    /// `#8E8E93` — `systemGray`, which resolves the same in both appearances.
    /// A row's subtitle, an unselected chip and, since the drawing moved it
    /// off `secondaryLabel`, a section header too.
    static let uiSecondaryText = UIColor.systemGray
    static let secondaryText = Color(uiColor: uiSecondaryText)

    /// The name above a card takes the same grey as a row's subtitle.
    static let sectionHeader = secondaryText

    /// A read-only trailing value: the row's own ink at 40%, not the subtitle
    /// grey. They are close in the light drawing and come apart in the dark,
    /// which is why this follows the label colour rather than freezing
    /// `#999999`.
    static let readOnlyValue = Color.primary.opacity(0.4)

    /// `#F7F7F7` under a finger — one step off the card, and it fills the
    /// whole row rather than tinting the label. Deliberately light: the press
    /// has to read against white without the row looking disabled.
    static let uiRowPressed = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? .tertiarySystemGroupedBackground
            : UIColor(white: 0xF7 / 255, alpha: 1)
    }
    static let rowPressed = Color(uiColor: uiRowPressed)

    /// The rule between two rows of the same card. It runs the full width of
    /// the card, and it is the page's own ground colour — not a grey of its
    /// own — so it reads as the card being cut rather than a line drawn on it.
    /// Pointing at the token rather than copying its value means the rule
    /// follows the ground if the ground ever moves again.
    ///
    /// Nothing under the last row: the card's edge already ends the group.
    static let uiSeparator = uiPageBackground
    static let separator = pageBackground
    static let separatorHeight: CGFloat = 1

    /// `#727272` for the subtitle under a title. Apple's own
    /// labels-vibrant/secondary, so it takes the role and gets the dark
    /// variant with it.
    static let subtitleText = Color(uiColor: .secondaryLabel)

    /// The disclosure chevron and the menu caret. `#E0E0E0` is close to
    /// `systemGray5` in light; the dark side takes the same step from the card.
    static let uiDisclosure = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? .systemGray4
            : UIColor(white: 0xE0 / 255, alpha: 1)
    }
    static let disclosure = Color(uiColor: uiDisclosure)

    /// `#B6B6B6` for the note under a card — one step quieter than a row's
    /// subtitle, because it is commentary rather than a value.
    static let uiFootnote = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? .systemGray2
            : UIColor(white: 0xB6 / 255, alpha: 1)
    }
    static let footnote = Color(uiColor: uiFootnote)

    /// `#34C759`, which is what `Toggle` already tints itself. Named so a row
    /// that needs the on-state colour outside a toggle uses the same value.
    static let toggleOn = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
}

// MARK: - Icons

/// A row's leading glyph, on the 24×24 artboard.
///
/// The drawing's three icons — the selection circle, the invoice, the region
/// globe — are vector assets exported from the same Figma file and drawn as
/// templates, so they take the row's foreground colour. Everywhere the page
/// needs a glyph the drawing does not name, an SF Symbol is set to the same
/// artboard and the same weight rather than a second, hand-drawn style.
enum SettingsIconSource: Equatable {
    case symbol(String)
    case asset(String)
}

struct SettingsRowIcon: View {
    let source: SettingsIconSource

    init(_ source: SettingsIconSource) {
        self.source = source
    }

    var body: some View {
        Group {
            switch source {
            case .symbol(let name):
                Image(systemName: name)
                    // The exported icons are stroked at 2 on a 24 box. A
                    // symbol at its natural 24pt weight reads thinner beside
                    // them, so it is set one step heavier.
                    .font(.system(size: 19, weight: .medium))
            case .asset(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: SettingsTemplate.iconSize, height: SettingsTemplate.iconSize)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}

/// The trailing chevron, 5×10 in `#E0E0E0`.
struct SettingsChevron: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("SettingsChevron")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(
                width: SettingsTemplate.chevronSize.width,
                height: SettingsTemplate.chevronSize.height
            )
            .foregroundStyle(SettingsTemplate.disclosure)
            .accessibilityHidden(true)
    }
}

/// The caret that marks a row as opening a menu, 8×5 in `#E0E0E0`.
struct SettingsCaret: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("SettingsCaretDown")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(
                width: SettingsTemplate.caretSize.width,
                height: SettingsTemplate.caretSize.height
            )
            .foregroundStyle(SettingsTemplate.disclosure)
            .accessibilityHidden(true)
    }
}

// MARK: - Page and section

/// A settings screen: the page grey, the 16pt column, and the 16pt rhythm
/// between everything stacked in it.
///
/// The screen's own title and subtitle stay on the navigation bar, where the
/// system draws the title at 34 bold, sets the subtitle under it, and folds
/// both into the small two-line title when the reader scrolls up — which is
/// the whole of the drawing's expanded and collapsed states.
struct SettingsPage<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String?
    let subtitle: String?
    /// Room for the floating tab bar on the root settings tab. A pushed page
    /// has no bar over it and passes its own, smaller value.
    var bottomInset: CGFloat = SettingsTemplate.rootTabBottomInset
    /// A large navigation title brings its own space under it. A page with an
    /// inline title does not, so it passes the page's own 16 and the first
    /// card sits off the bar by the same gap everything else uses.
    var topInset: CGFloat = 0
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        bottomInset: CGFloat = SettingsTemplate.rootTabBottomInset,
        topInset: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.bottomInset = bottomInset
        self.topInset = topInset
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsTemplate.sectionSpacing) {
                // Under the large title, on the title's own left edge — the
                // drawing's expanded state. Not `navigationSubtitle`: that
                // draws the drawing's *collapsed* state and forces the bar
                // inline for good, so a screen using it never shows a large
                // title at all.
                if let subtitle {
                    SettingsPageSubtitle(subtitle)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsTemplate.pageInset)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .background(SettingsImmediateTouchFeedback())
            // Associate only this page's scroll view with its native bar,
            // before the first visible frame and again after a return.
            .background(NavigationBarScrollAnchor().accessibilityHidden(true))
        }
        .scrollContentBackground(.hidden)
        .background(SettingsTemplate.pageBackground)
        // Every settings page has a bar over it — the tab's large title or a
        // pushed page's — so the page container carries the soft edge once.
        .softTopScrollEdge()
        .settingsNavigationTitle(title)
    }
}

/// Remove the scroll view's touch-down delay, not its gesture arbitration.
/// Native buttons still cancel when a press becomes a scroll. Configure only
/// this page's scroll view; no appearance proxy or replacement tap gesture.
struct SettingsImmediateTouchFeedback: UIViewRepresentable {
    func makeUIView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: BoundaryView, context: Context) {
        view.configureScrollView()
        // SwiftUI can finish attaching or updating its scroll view later in
        // the same run loop, including after a native navigation transition.
        DispatchQueue.main.async { [weak view] in view?.configureScrollView() }
    }

    static func dismantleUIView(_ view: BoundaryView, coordinator: ()) {
        view.deactivate()
    }

    final class BoundaryView: UIView {
        private weak var configuredScrollView: UIScrollView?
        private var previousDelay: Bool?
        private var isActive = true

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureScrollView()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            configureScrollView()
        }

        func configureScrollView() {
            guard isActive else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    if configuredScrollView !== scrollView {
                        restoreScrollView()
                        configuredScrollView = scrollView
                        previousDelay = scrollView.delaysContentTouches
                    }
                    scrollView.delaysContentTouches = false
                    return
                }
                ancestor = view.superview
            }
        }

        func restoreScrollView() {
            if let previousDelay { configuredScrollView?.delaysContentTouches = previousDelay }
            configuredScrollView = nil
            previousDelay = nil
        }

        func deactivate() {
            isActive = false
            restoreScrollView()
        }
    }
}

/// The subtitle under a large title: SF 15 Medium in `#727272`, sitting on the
/// title's own left edge.
struct SettingsPageSubtitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .appText(.callout, weight: .medium)
            .foregroundStyle(SettingsTemplate.subtitleText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Names the screen on the navigation bar.
    ///
    /// The display mode is set beside the title rather than left to the call
    /// site: the drawing's two states are the large title and what it
    /// collapses into, and a screen that starts inline never shows the first.
    @ViewBuilder
    func settingsNavigationTitle(_ title: String?) -> some View {
        if let title {
            self.navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
        } else {
            self
        }
    }
}

/// A header, then its card. Nothing between them but the page's own 14.
struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        // The section's two parts are separate children of the page stack, so
        // header-to-card is the same 14 as card-to-header. A nested stack with
        // its own spacing would make one of the two gaps different.
        Group {
            if let title {
                SettingsSectionHeader(title)
            }
            SettingsCard { content }
        }
    }
}

/// The name above a card. SF Rounded Medium at 16 — the same size as a row's
/// title, one weight up and in the secondary grey, so a section reads as a
/// heading of the list rather than a smaller caption above it.
struct SettingsSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .appText(.body, weight: .medium)
            .foregroundStyle(SettingsTemplate.sectionHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SettingsTemplate.sectionHeaderTopSpacing)
    }
}

/// One white card. Rows inside it are flush against each other with no rule
/// between them — the card is clipped once, so the first and last rows pick up
/// the 24pt corners without each needing to know where it sits.
struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // The card puts the rule between its rows itself, so no call site has
        // to know whether it is the last row of a group. `_VariadicView` is
        // how SwiftUI exposes a container's children for exactly this; if it
        // ever goes away, the fallback is an explicit `isLast` on every row.
        _VariadicView.Tree(SettingsCardRows()) { content }
            .background(SettingsTemplate.card)
            .clipShape(RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous))
    }
}

private struct SettingsCardRows: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    SettingsTemplate.separator
                        .frame(height: SettingsTemplate.separatorHeight)
                }
            }
        }
    }
}

/// The note under a card. 12pt, quieter than a subtitle, set on 1.4 and inset
/// to the card's text column.
struct SettingsFootnote: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    /// A note that reports a failure takes the danger colour; everything else
    /// takes the quiet grey.
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    /// Several paragraphs under one card — a set-up instruction that runs to
    /// more than a sentence. They stack inside the note's own block so the gap
    /// to the card above stays 10 however many lines there are.
    init(_ paragraphs: [String], color: Color? = nil) {
        self.text = paragraphs.joined(separator: "\n\n")
        self.color = color
    }

    var body: some View {
        Text(text)
            .appText(.caption)
            .foregroundStyle(color ?? SettingsTemplate.footnote)
            .lineSpacing(SettingsTemplate.footnoteLineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsTemplate.footnoteInset)
            // Pulled back against the page's own gap so the note lands 10
            // under the card it explains rather than a full section away.
            .padding(.top, SettingsTemplate.footnoteTopSpacing - SettingsTemplate.sectionSpacing)
    }
}

// MARK: - Row internals

/// The 20/16 padding, the minimum height and the tap target every row shares.
struct SettingsRowContainer<Content: View>: View {
    var minHeight: CGFloat = SettingsTemplate.rowMinHeight
    var verticalPadding: CGFloat = SettingsTemplate.rowVerticalPadding
    @ViewBuilder let content: Content

    init(
        minHeight: CGFloat = SettingsTemplate.rowMinHeight,
        verticalPadding: CGFloat = SettingsTemplate.rowVerticalPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.minHeight = minHeight
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Icon, title, the row's value, and the subtitle under them.
///
/// The value sits on the title's line rather than beside the whole block, so a
/// row with an explanation under it keeps that explanation on its own full
/// width instead of being squeezed into the column the value leaves — the way
/// the drawing sets 语言 (title and value on one line) and 账单 (title, then
/// the line that explains it).
struct SettingsRowLabel: View {
    /// A row that is switched off has to look switched off. `.buttonStyle(.plain)`
    /// keeps the label's own colours, so the dimming is applied here.
    @Environment(\.isEnabled) private var isEnabled
    let icon: SettingsIconSource?
    let title: String
    var subtitle: String?
    /// Overridden only where the drawing sets a different one — the invoice
    /// row stacks its two lines at 2 rather than 4.
    var subtitleSpacing: CGFloat = SettingsTemplate.subtitleSpacing
    var subtitleColor: Color = SettingsTemplate.secondaryText
    /// A figure-bearing subtitle ("78 项 · $22,106") goes through the number
    /// token so its digits match the rest of the app.
    var subtitleIsNumeric = false
    /// Set only where the row means something other than "open this" — a
    /// destructive action.
    var titleColor: Color?
    var value: String?
    /// Overridden where the value is a state rather than a fact — a service
    /// that is connected or not.
    var valueColor: Color?
    var valueIsNumeric = true

    var body: some View {
        HStack(spacing: SettingsTemplate.iconSpacing) {
            if let icon {
                SettingsRowIcon(icon)
                    .foregroundStyle(titleColor ?? .primary)
            }
            VStack(alignment: .leading, spacing: subtitleSpacing) {
                HStack(spacing: SettingsTemplate.valueSpacing) {
                    Text(title)
                        .appText(.subheading)
                        .foregroundStyle(titleColor ?? .primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if let value {
                        Group {
                            if valueIsNumeric {
                                Text(value).appNumber(.subheading, weight: .regular, monospaced: false)
                            } else {
                                Text(value).appText(.subheading)
                            }
                        }
                        .foregroundStyle(valueColor ?? SettingsTemplate.readOnlyValue)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }
                if let subtitle {
                    Group {
                        if subtitleIsNumeric {
                            Text(subtitle).appNumber(.label, weight: .regular, monospaced: false)
                        } else {
                            Text(subtitle).appText(.label, weight: .regular)
                        }
                    }
                    .foregroundStyle(subtitleColor)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Fills the row while it is held. The drawing gives the whole row the tint,
/// not the label, so the style paints behind `SettingsRowContainer` and the
/// card's own clip rounds it into the corners on the first and last rows.
struct SettingsRowButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                (configuration.isPressed ? SettingsTemplate.rowPressed : .clear)
                    .animation(nil, value: configuration.isPressed)
            }
    }
}

/// Reports the press instead of drawing it, for a row that holds two controls
/// and wants one fill across the whole of it.
struct SettingsRowPressReporter: ButtonStyle {
    let isPressed: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in isPressed(pressed) }
    }
}

// MARK: - Rows

/// A row that pushes a page.
struct SettingsNavigationRow<Destination: View>: View {
    let icon: SettingsIconSource?
    let title: String
    var subtitle: String?
    var subtitleSpacing: CGFloat = SettingsTemplate.subtitleSpacing
    var subtitleIsNumeric = false
    /// The current answer, shown at the trailing edge of the title's line in
    /// the same grey a read-only value gets.
    var value: String?
    var valueColor: Color?
    @ViewBuilder let destination: Destination

    init(
        icon: SettingsIconSource? = nil,
        title: String,
        subtitle: String? = nil,
        subtitleSpacing: CGFloat = SettingsTemplate.subtitleSpacing,
        subtitleIsNumeric: Bool = false,
        value: String? = nil,
        valueColor: Color? = nil,
        @ViewBuilder destination: () -> Destination
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.subtitleSpacing = subtitleSpacing
        self.subtitleIsNumeric = subtitleIsNumeric
        self.value = value
        self.valueColor = valueColor
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsRowContainer {
                HStack(spacing: SettingsTemplate.iconSpacing) {
                    SettingsRowLabel(
                        icon: icon,
                        title: title,
                        subtitle: subtitle,
                        subtitleSpacing: subtitleSpacing,
                        subtitleIsNumeric: subtitleIsNumeric,
                        value: value,
                        valueColor: valueColor,
                        valueIsNumeric: false
                    )
                    SettingsChevron()
                }
            }
        }
        .buttonStyle(SettingsRowButtonStyle())
    }
}

/// A row that runs an action — opening a sheet, starting a flow.
struct SettingsButtonRow: View {
    let icon: SettingsIconSource?
    let title: String
    var subtitle: String?
    var subtitleSpacing: CGFloat = SettingsTemplate.subtitleSpacing
    var showsChevron = true
    /// The current answer, where the row reports one — "3 笔", "已连接".
    var value: String?
    var valueColor: Color?
    /// Swaps the chevron for a spinner while the row's action is running.
    var showsProgress = false
    var role: ButtonRole?
    /// Set where the row's own state says something a grey title cannot — a
    /// copy that has just succeeded.
    var tint: Color?
    let action: () -> Void

    /// A destructive row is red — title and icon both. `.buttonStyle(.plain)`
    /// keeps the label's own colours, so the role is applied here rather than
    /// left to the button.
    private var titleColor: Color? {
        role == .destructive ? CatfolioTheme.danger : tint
    }

    init(
        icon: SettingsIconSource? = nil,
        title: String,
        subtitle: String? = nil,
        subtitleSpacing: CGFloat = SettingsTemplate.subtitleSpacing,
        showsChevron: Bool = true,
        value: String? = nil,
        valueColor: Color? = nil,
        showsProgress: Bool = false,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.subtitleSpacing = subtitleSpacing
        self.showsChevron = showsChevron
        self.value = value
        self.valueColor = valueColor
        self.showsProgress = showsProgress
        self.role = role
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            SettingsRowContainer {
                HStack(spacing: SettingsTemplate.iconSpacing) {
                    SettingsRowLabel(
                        icon: icon,
                        title: title,
                        subtitle: subtitle,
                        subtitleSpacing: subtitleSpacing,
                        titleColor: titleColor,
                        value: value,
                        valueColor: valueColor
                    )
                    if showsProgress {
                        ProgressView().controlSize(.small)
                    } else if showsChevron {
                        SettingsChevron()
                    }
                }
            }
        }
        .buttonStyle(SettingsRowButtonStyle())
    }
}

/// A switch. The control is the system's, so it is 64×28 with the 38×24 pill
/// knob and `#34C759` on — which is what the drawing is, because the drawing
/// is Apple's own toggle component.
struct SettingsToggleRow: View {
    let icon: SettingsIconSource?
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    init(icon: SettingsIconSource? = nil, title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        SettingsRowContainer {
            Toggle(isOn: $isOn) {
                SettingsRowLabel(icon: icon, title: title, subtitle: subtitle)
            }
            .tint(SettingsTemplate.toggleOn)
        }
    }
}

/// A row that only reports a value. The value is grey; nothing opens.
struct SettingsValueRow: View {
    let icon: SettingsIconSource?
    let title: String
    let value: String?
    var valueIsNumeric = true

    init(icon: SettingsIconSource? = nil, title: String, value: String?, valueIsNumeric: Bool = true) {
        self.icon = icon
        self.title = title
        self.value = value
        self.valueIsNumeric = valueIsNumeric
    }

    var body: some View {
        SettingsRowContainer {
            SettingsRowLabel(
                icon: icon,
                title: title,
                value: value,
                valueIsNumeric: valueIsNumeric
            )
        }
    }
}

/// A text field on the row's own padding, with room for a control beside it.
///
/// The field itself is the system's `TextField`/`SecureField` — the row only
/// supplies the 20/16, the minimum height and the type, so autofill, the
/// keyboard, `privacySensitive` and the rest keep behaving as they did.
struct SettingsFieldRow<Accessory: View>: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    /// A credential reads as a string of characters, not as prose, so keys get
    /// the fixed-width face the platform uses for them.
    var isMonospaced = false
    @ViewBuilder let accessory: Accessory

    init(
        _ placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        isMonospaced: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.isMonospaced = isMonospaced
        self.accessory = accessory()
    }

    var body: some View {
        SettingsRowContainer {
            HStack(spacing: SettingsTemplate.iconSpacing) {
                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .modifier(SettingsFieldFont(isMonospaced: isMonospaced))
                accessory
            }
        }
    }
}

extension SettingsFieldRow where Accessory == EmptyView {
    init(
        _ placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        isMonospaced: Bool = false
    ) {
        self.init(
            placeholder,
            text: text,
            isSecure: isSecure,
            isMonospaced: isMonospaced,
            accessory: { EmptyView() }
        )
    }
}

private struct SettingsFieldFont: ViewModifier {
    let isMonospaced: Bool

    func body(content: Content) -> some View {
        if isMonospaced {
            content.font(.body.monospaced())
        } else {
            content.appText(.subheading)
        }
    }
}

/// A row whose value opens a menu. The value is in the primary colour, not
/// grey — the drawing distinguishes a value you can change from one you cannot
/// by exactly that, plus the caret beside it.
struct SettingsMenuRow<SelectionValue: Hashable, Options: View>: View {
    let icon: SettingsIconSource?
    let title: String
    let value: String
    @Binding var selection: SelectionValue
    @ViewBuilder let options: Options

    init(
        icon: SettingsIconSource? = nil,
        title: String,
        value: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder options: () -> Options
    ) {
        self.icon = icon
        self.title = title
        self.value = value
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        SettingsRowContainer {
            HStack(spacing: SettingsTemplate.iconSpacing) {
                SettingsRowLabel(icon: icon, title: title)
                // A `Menu` wrapping a `Picker`: the menu takes the row's own
                // value-and-caret as its label, and the picker inside still
                // supplies the options, the check beside the current one and
                // the selection binding.
                Menu {
                    Picker(selection: $selection) {
                        options
                    } label: {
                        EmptyView()
                    }
                } label: {
                    HStack(spacing: SettingsTemplate.valueSpacing) {
                        Text(value)
                            .appText(.subheading)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        SettingsCaret()
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(value)
            }
        }
    }
}

/// The account rows: a selection circle in the icon slot, the account under
/// it, and a chevron when the row also opens a page.
///
/// Two controls in one row, so they are two buttons rather than one — tapping
/// the circle changes what the portfolio counts, tapping the rest opens the
/// account.
struct SettingsSelectionRow<Destination: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Both halves report into one flag so the fill covers the whole row,
    /// whichever half is being held.
    @State private var isPressed = false
    let isSelected: Bool
    let title: String
    var subtitle: String?
    var subtitleColor: Color = SettingsTemplate.secondaryText
    var selectionAccessibilityLabel: String
    var selectionAccessibilityHint: String?
    let toggle: () -> Void
    let opensDestination: Bool
    @ViewBuilder let destination: Destination

    init(
        isSelected: Bool,
        title: String,
        subtitle: String? = nil,
        subtitleColor: Color = SettingsTemplate.secondaryText,
        selectionAccessibilityLabel: String,
        selectionAccessibilityHint: String? = nil,
        toggle: @escaping () -> Void,
        @ViewBuilder destination: () -> Destination
    ) {
        self.isSelected = isSelected
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.selectionAccessibilityLabel = selectionAccessibilityLabel
        self.selectionAccessibilityHint = selectionAccessibilityHint
        self.toggle = toggle
        self.opensDestination = true
        self.destination = destination()
    }

    var body: some View {
        SettingsRowContainer {
            HStack(spacing: SettingsTemplate.iconSpacing) {
                Button(action: toggle) {
                    SettingsRowIcon(.asset(isSelected ? "SettingsSelectOn" : "SettingsSelectOff"))
                        // The circle needs a target taller than 24pt without
                        // making the row taller: padded out for the hit shape,
                        // then pulled back in so the layout still measures the
                        // 24pt artboard the drawing places here.
                        .padding(.vertical, SettingsTemplate.rowVerticalPadding)
                        .contentShape(Rectangle())
                        .padding(.vertical, -SettingsTemplate.rowVerticalPadding)
                }
                .buttonStyle(SettingsRowPressReporter { isPressed = $0 })
                .accessibilityLabel(selectionAccessibilityLabel)
                .accessibilityValue(isSelected ? L10n.text("已选择") : L10n.text("未选择"))
                .accessibilityHint(selectionAccessibilityHint ?? "")

                if opensDestination {
                    NavigationLink {
                        destination
                    } label: {
                        HStack(spacing: SettingsTemplate.iconSpacing) {
                            stackedText
                            SettingsChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsRowPressReporter { isPressed = $0 })
                } else {
                    stackedText
                }
            }
        }
        .background {
            (isPressed ? SettingsTemplate.rowPressed : .clear)
                .animation(nil, value: isPressed)
        }
    }

    private var stackedText: some View {
        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
            Text(title)
                .appText(.subheading)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .appNumber(.label, weight: .regular, monospaced: false)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsSelectionRow where Destination == EmptyView {
    /// The row that only changes what is counted — the drawing's 全部账户,
    /// which has no page behind it and so no chevron.
    init(
        isSelected: Bool,
        title: String,
        subtitle: String? = nil,
        selectionAccessibilityLabel: String,
        selectionAccessibilityHint: String? = nil,
        toggle: @escaping () -> Void
    ) {
        self.isSelected = isSelected
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = SettingsTemplate.secondaryText
        self.selectionAccessibilityLabel = selectionAccessibilityLabel
        self.selectionAccessibilityHint = selectionAccessibilityHint
        self.toggle = toggle
        self.opensDestination = false
        self.destination = EmptyView()
    }
}
