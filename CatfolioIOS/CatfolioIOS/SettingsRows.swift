import SwiftUI
import UIKit

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
    @Environment(\.accountFlowTheme) private var accountTheme
    /// A row that is switched off has to look switched off. `.buttonStyle(.plain)`
    /// keeps the label's own colours, so the dimming is applied here.
    @Environment(\.isEnabled) private var isEnabled
    let icon: SettingsIconSource?
    let title: String
    var subtitle: String?
    /// Overridden only where the drawing sets a different one — the invoice
    /// row stacks its two lines at 2 rather than 4.
    var subtitleSpacing: CGFloat = SettingsTemplate.subtitleSpacing
    var subtitleColor: Color = SettingsTemplate.subtitleText
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
                SettingsRowIcon(icon, tint: accountTheme.map { titleColor ?? $0.controlTint })
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
                                FinancialText(value).appNumber(.subheading, weight: .regular, monospaced: false)
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
                            FinancialText(subtitle).appNumber(.label, weight: .regular, monospaced: false)
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
        // The Mac pointer lights the row at half strength.
        MacHover { isHovered in
            configuration.label
                .background {
                    SettingsTemplate.rowPressed
                        .opacity(configuration.isPressed ? 1 : (isHovered ? 0.5 : 0))
                        .animation(nil, value: configuration.isPressed)
                }
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

/// Explicitly use the native capsule switch on every platform; the Mac's
/// automatic toggle style otherwise renders a checkbox.
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
            .toggleStyle(.switch)
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

/// A row whose current selection uses the same grey as other trailing values.
/// The caret and menu interaction indicate that the value can be changed.
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
                    // On the Mac a menu picker nested in a menu becomes an
                    // untitled submenu, and the menu opened empty.
                    .modifier(MacInlinePicker())
                } label: {
                    HStack(spacing: SettingsTemplate.valueSpacing) {
                        Text(value)
                            .appText(.subheading)
                            .foregroundStyle(SettingsTemplate.readOnlyValue)
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
    @Environment(\.accountFlowTheme) private var accountTheme
    /// Both halves report into one flag so the fill covers the whole row,
    /// whichever half is being held.
    @State private var isPressed = false
    let isSelected: Bool
    let title: String
    var subtitle: String?
    var subtitleColor: Color = SettingsTemplate.subtitleText
    var selectionAccessibilityLabel: String
    var selectionAccessibilityHint: String?
    let toggle: () -> Void
    let opensDestination: Bool
    @ViewBuilder let destination: Destination

    init(
        isSelected: Bool,
        title: String,
        subtitle: String? = nil,
        subtitleColor: Color = SettingsTemplate.subtitleText,
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
                    SettingsRowIcon(.asset(isSelected ? "SettingsSelectOn" : "SettingsSelectOff"),
                                    tint: isSelected ? accountTheme?.controlTint : nil)
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
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
            if let subtitle {
                FinancialText(subtitle)
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
        self.subtitleColor = SettingsTemplate.subtitleText
        self.selectionAccessibilityLabel = selectionAccessibilityLabel
        self.selectionAccessibilityHint = selectionAccessibilityHint
        self.toggle = toggle
        self.opensDestination = false
        self.destination = EmptyView()
    }
}
