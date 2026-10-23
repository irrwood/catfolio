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
    /// Breathing room under the last card on root tabs. The system tab bar
    /// already insets the scroll view by its own height.
    static let rootTabBottomInset: CGFloat = 24
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
    /// Provider badges on the add-account page (Figma 630:23915).
    static let accountProviderIconSize: CGFloat = 56
    static let accountActionGlyphSize: CGFloat = 32
    static let accountConnectGlyphOffsetY: CGFloat = 0.5
    static let accountProviderIconRadius: CGFloat = 16
    /// These bitmap artboards include padding around tall, asymmetric marks.
    static let accountBrokerArtworkSize: CGFloat = 44
    static let accountIBKRArtworkOffsetY: CGFloat = -1
    static let accountRobinhoodArtworkOffsetY: CGFloat = 1.5
    static let accountActionIconBorderWidth: CGFloat = 0.848
    static let accountProviderRowHeight: CGFloat = 96
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
            let to = CatfolioTheme.primaryTextUIColor.resolvedColor(with: trait)
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

    /// `#F3F3F3` by day, black at night (Figma 571:5939 / 571:6350). The
    /// cards carry their own hairline outline, so the ground no longer has to
    /// be a deep grey for them to read as lifted off it.
    static let uiPageBackground = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? .black
            : UIColor(white: 0xF3 / 255, alpha: 1)
    }
    static let pageBackground = Color(uiColor: uiPageBackground)

    /// The card fill: white, and at night `#1D1E1E` — the standard cell's
    /// fill, a step above both the black page and a sheet's `#141515` ground.
    /// The opaque fallback for content panels and the fill for compact
    /// controls. Grouped panels normally blend the page through a material.
    static let uiCard = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x1D / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
            : .white
    }
    static let card = Color(uiColor: uiCard)

    static let accountConnectGradient = LinearGradient(
        colors: [CatfolioPalette.accountConnectTop, CatfolioPalette.accountConnectBottom],
        startPoint: .top, endPoint: .bottom)
    static let accountImportGradient = RadialGradient(
        colors: [CatfolioPalette.accountImportTop, CatfolioPalette.accountImportBottom],
        center: UnitPoint(x: 0.5, y: 0.5 / accountProviderIconSize),
        startRadius: 0, endRadius: accountProviderIconSize - 0.5)

    /// The card's faint outline, 1 pt all round: 5% of the ink — black by
    /// day, white at night.
    static let uiCardBorder = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.05)
            : UIColor(white: 0, alpha: 0.05)
    }
    static let cardBorder = Color(uiColor: uiCardBorder)
    static let cardBorderWidth: CGFloat = 1

    /// Editable fields need an opaque surface and a visible edge on both
    /// white onboarding pages and grouped settings backgrounds.
    static let inputBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBorder = Color(uiColor: .opaqueSeparator)

    /// A row's subtitle and an unselected chip: translucent ink, like the
    /// section names, so it takes the tone of the translucent panel under it.
    /// A fixed grey fell to about 2.7:1 on the blue-tinted night panels; white
    /// at 60% keeps ~4.4:1. By day black at 50% (`#808080` on white), a touch
    /// darker than the `systemGray` it replaces.
    static let uiSecondaryText = UIColor { trait in
        let high = trait.accessibilityContrast == .high
        return trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(high ? 0.8 : 0.6)
            : UIColor.black.withAlphaComponent(high ? 0.7 : 0.5)
    }
    static let secondaryText = Color(uiColor: uiSecondaryText)

    /// Section names use translucent ink, so their tone follows the actual
    /// page beneath them rather than a fixed system grey.
    static let uiSectionHeader = UIColor { trait in
        (trait.userInterfaceStyle == .dark ? UIColor.white : UIColor.black)
            .withAlphaComponent(trait.accessibilityContrast == .high ? 0.8 : 0.6)
    }
    static let sectionHeader = Color(uiColor: uiSectionHeader)

    /// Trailing row values, including current selections: ink at 40%, not the subtitle
    /// grey. They are close in the light drawing and come apart in the dark,
    /// which is why this follows the label colour rather than freezing
    /// `#999999`.
    static let readOnlyValue = Color.primary.opacity(0.4)

    /// Translucent ink under a finger — one step off the panel, filling the
    /// whole row rather than tinting the label, and taking the panel's own
    /// tone. Black at 3% is the drawing's `#F7F7F7` on a white card; white at
    /// 6% on a night panel is the step `#2C2C2E` used to take. Deliberately
    /// light: the press has to read without the row looking disabled.
    static let uiRowPressed = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.06)
            : UIColor.black.withAlphaComponent(0.03)
    }
    static let rowPressed = Color(uiColor: uiRowPressed)

    /// The rule between two rows of the same card, running its full width:
    /// `#EEEFEF` by day; at night 5% white over the card, which is `#282929`.
    /// Opaque, so it reads the same on any card fill underneath.
    ///
    /// Nothing under the last row: the card's edge already ends the group.
    static let uiSeparator = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x28 / 255, green: 0x29 / 255, blue: 0x29 / 255, alpha: 1)
            : UIColor(red: 0xEE / 255, green: 0xEF / 255, blue: 0xEF / 255, alpha: 1)
    }
    static let separator = Color(uiColor: uiSeparator)
    static let separatorHeight: CGFloat = 1

    /// The 13 pt line under a row's title: `#8E8E93` by day, white at 30%
    /// at night.
    static let subtitleText = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.3) : .systemGray
    })

    /// The disclosure chevron and the menu caret: translucent ink, like a
    /// row's subtitle, so it takes the tone of the panel under it. Black at
    /// 12% is the drawing's `#E0E0E0` on a white card; at night white at 18%
    /// stands a little clearer of the translucent panel than `systemGray4` did.
    static let uiDisclosure = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.12)
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
    case brandAsset(String)
}

struct SettingsRowIcon: View {
    let source: SettingsIconSource
    var tint: Color?

    init(_ source: SettingsIconSource, tint: Color? = nil) {
        self.source = source
        self.tint = tint
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
            case .brandAsset(let name):
                Image(name)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            case .asset(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: SettingsTemplate.iconSize, height: SettingsTemplate.iconSize)
        .foregroundStyle(tint ?? CatfolioTheme.primaryText)
        .accessibilityHidden(true)
    }
}

/// The trailing chevron, 5×10 in the disclosure ink.
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

/// The caret that marks a row as opening a menu, 8×5 in the disclosure ink.
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
    let pageBackground: Color
    /// Room for the floating tab bar on the root settings tab. A pushed page
    /// has no bar over it and passes its own, smaller value.
    var bottomInset: CGFloat = SettingsTemplate.rootTabBottomInset
    /// A large navigation title brings its own space under it. A page with an
    /// inline title does not, so it passes the page's own 16 and the first
    /// card sits off the bar by the same gap everything else uses.
    var topInset: CGFloat = 0
    /// Large for a tab's own page; Settings and the pages inside it use the
    /// system's small inline bar.
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode = .large
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        bottomInset: CGFloat = SettingsTemplate.rootTabBottomInset,
        topInset: CGFloat = 0,
        titleDisplayMode: NavigationBarItem.TitleDisplayMode = .large,
        pageBackground: Color = SettingsTemplate.pageBackground,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.bottomInset = bottomInset
        self.topInset = topInset
        self.titleDisplayMode = titleDisplayMode
        self.pageBackground = pageBackground
        self.content = content()
    }

    var body: some View {
        // Let NavigationStack own the scroll association through push/pop and
        // title collapse. A child controller must not rebind it during layout.
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
        }
        .scrollContentBackground(.hidden)
        .appPageBackground(pageBackground)
        // Every settings page has a bar over it — the tab's large title or a
        // pushed page's — so the page container carries the soft edge once.
        .softTopScrollEdge()
        .settingsNavigationTitle(title, displayMode: titleDisplayMode)
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
    func settingsListRow() -> some View {
        listRowBackground(SettingsTemplate.card)
            .listRowSeparatorTint(SettingsTemplate.separator)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    }

    /// Names the screen on the navigation bar.
    ///
    /// The display mode is set beside the title rather than left to the call
    /// site: the drawing's two states are the large title and what it
    /// collapses into, and a screen that starts inline never shows the first.
    @ViewBuilder
    func settingsNavigationTitle(_ title: String?,
                                 displayMode: NavigationBarItem.TitleDisplayMode = .large) -> some View {
        if let title {
            self.navigationTitle(title)
                .navigationBarTitleDisplayMode(displayMode)
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
/// title, one weight up and in translucent ink, so a section reads as a
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
            // Inset to the rows' text column, 20 pt in from the card's edge,
            // as the standard cell's frame sets it (Figma 571:5951).
            .padding(.leading, SettingsTemplate.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SettingsTemplate.sectionHeaderTopSpacing)
    }
}

enum SettingsCardStyle {
    case content
    case input
    case accountInput
}

/// One surface behind the whole group, with a subtle rule between rows.
/// Clip once so the first and last rows inherit the panel's outer corners.
struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var style: SettingsCardStyle
    @ViewBuilder let content: Content

    init(style: SettingsCardStyle = .content, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .content:
            rows.settingsCardSurface()
        case .input:
            let shape = RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
            rows
                .background(SettingsTemplate.inputBackground, in: shape)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(SettingsTemplate.inputBorder, lineWidth: SettingsTemplate.cardBorderWidth)
                        .allowsHitTesting(false)
                }
        case .accountInput:
            let shape = RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
            rows
                .background(SettingsTemplate.card, in: shape)
                .clipShape(shape)
                .shadow(color: colorScheme == .dark ? .clear : CatfolioPalette.accountCredentialShadow,
                        radius: 18, x: 0, y: 2)
        }
    }

    private var rows: some View {
        // The card puts the rule between its rows itself, so no call site has
        // to know whether it is the last row of a group. `_VariadicView` is
        // how SwiftUI exposes a container's children for exactly this; if it
        // ever goes away, the fallback is an explicit `isLast` on every row.
        _VariadicView.Tree(SettingsCardRows()) { content }
    }
}

extension View {
    /// A virtualized list row forms one slice of the same surface as SettingsCard.
    /// Extend hidden corners beyond interior rows so only the group's outer
    /// border is drawn, without building every transaction in a single cell.
    func settingsListRow(isFirst: Bool, isLast: Bool) -> some View {
        frame(minHeight: SettingsTemplate.rowMinHeight - 2 * SettingsTemplate.rowVerticalPadding)
            .listRowInsets(EdgeInsets(top: SettingsTemplate.rowVerticalPadding,
                leading: SettingsTemplate.rowHorizontalPadding,
                bottom: SettingsTemplate.rowVerticalPadding,
                trailing: SettingsTemplate.rowHorizontalPadding))
            .listRowBackground(
                GeometryReader { geometry in
                    let top = isFirst ? CGFloat.zero : SettingsTemplate.cardRadius
                    let bottom = isLast ? CGFloat.zero : SettingsTemplate.cardRadius
                    let shape = RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
                    shape.fill(SettingsTemplate.card)
                        .overlay {
                            shape.strokeBorder(SettingsTemplate.cardBorder, lineWidth: SettingsTemplate.cardBorderWidth)
                        }
                        .frame(height: geometry.size.height + top + bottom)
                        .offset(y: -top)
                }
                .clipped()
                .allowsHitTesting(false)
            )
            .listRowSeparator(isLast ? .hidden : .visible, edges: .bottom)
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparatorTint(SettingsTemplate.separator)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    }

    /// The shared content panel: background colour through system blur,
    /// a neutral readability wash, and a hairline around the whole group.
    func settingsCardSurface(cornerRadius: CGFloat = SettingsTemplate.cardRadius) -> some View {
        modifier(ContentPanelSurface(cornerRadius: cornerRadius))
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
                    ContentPanelSeparator()
                }
            }
        }
    }
}

/// The note under a card. 12pt, quieter than a subtitle, set on 1.4 and inset
/// to the card's text column.
struct SettingsFootnote: View {
    @Environment(\.locale) private var appLocale
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
        Text(L10n.message(text))
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
