import SwiftUI
import UIKit

/// Shared credential controls for service keys and the broker setup flow.
struct ServiceAPIKeyInput: View {
    let placeholder: String
    @Binding var text: String
    @Binding var revealsKey: Bool
    var accessibilityIdentifier = "local-service.api-key"
    var isAccountCredential = false
    @Environment(\.accountFlowTheme) private var accountTheme
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var visibilityTaps = 0

    var body: some View {
        HStack(spacing: 8) {
            ServiceAPIKeyField(placeholder: placeholder, text: $text, revealsKey: revealsKey,
                               accessibilityIdentifier: accessibilityIdentifier,
                               usesRoundedFont: isAccountCredential)
                .privacySensitive()

            if !isAccountCredential || !text.isEmpty {
                Button {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { revealsKey.toggle() }
                    visibilityTaps += 1
                } label: {
                    SettingsRowIcon(.asset(revealsKey
                        ? (isAccountCredential ? "AccountCredentialVisibility" : "CredentialEyesOpen")
                        : "CredentialEyesClosed"),
                                    tint: isAccountCredential ? (accountTheme?.accent ?? CatfolioTheme.primaryText) : SettingsTemplate.secondaryText)
                        .id(revealsKey)
                        .contentTransition(.identity)
                        .transition(.identity)
                        // Keep the 44pt hit area, but place the 24pt artwork 18pt
                        // from the row edge: 14pt inset + 10pt centering - 6pt.
                        .offset(x: isAccountCredential ? 6 : 0)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transaction {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
                .sensoryFeedback(.selection, trigger: visibilityTaps) { _, _ in hapticsEnabled }
                .padding(.vertical, -8)
                .accessibilityLabel(revealsKey ? L10n.text("隐藏 API 密钥") : L10n.text("显示 API 密钥"))
                .accessibilityValue(placeholder)
                .accessibilityIdentifier(accessibilityIdentifier + ".visibility")
            }

            if isAccountCredential {
                if text.isEmpty {
                    AccountCredentialPasteButton(text: $text,
                        accessibilityIdentifier: accessibilityIdentifier + ".paste")
                }
            } else {
                ServiceAPIKeyPasteControl(text: $text, accessibilityIdentifier: accessibilityIdentifier + ".paste")
                    .id(colorScheme)
                    .fixedSize()
                    .padding(.vertical, -8)
            }
        }
    }
}

/// Figma 750:2007 uses a medium glass text button, not UIPasteControl's fixed typography.
struct AccountCredentialPasteButton: UIViewRepresentable {
    @Binding var text: String
    let accessibilityIdentifier: String
    @ScaledMetric(relativeTo: .footnote) private var labelSize = 14

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(context.coordinator, action: #selector(Coordinator.paste), for: .touchUpInside)
        button.accessibilityIdentifier = accessibilityIdentifier
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isEnabled = context.environment.isEnabled
        let font = CurrencySymbolAlternates.font(size: labelSize, weight: .medium, rounded: true)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) { configuration = .prominentGlass() }
        else { configuration = .filled() }
        configuration.title = L10n.text("粘贴").uppercased()
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = font
            return attributes
        }
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        // SF Rounded on the device has slightly wider glyph metrics than the Figma font.
        // Keep the 66pt capsule and center the complete 14pt label without shrinking it.
        let labelWidth = (L10n.text("粘贴").uppercased() as NSString).size(withAttributes: [.font: font]).width
        let horizontalInset = min(12, max(0, (66 * labelSize / 14 - labelWidth) / 2))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: horizontalInset, bottom: 7, trailing: horizontalInset)
        configuration.baseBackgroundColor = UIColor(context.environment.accountFlowTheme?.accent ?? CatfolioTheme.accent)
        configuration.baseForegroundColor = context.environment.usesPaywallOnboardingStyle
            ? UIColor(AccountFlowTheme.firstLaunch.onAccent) : .white
        button.configuration = configuration
        button.isEnabled = context.environment.isEnabled
        button.accessibilityLabel = L10n.text("粘贴")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let scale = labelSize / 14
        return CGSize(width: 66 * scale, height: 32 * scale)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject {
        var text: Binding<String>
        var isEnabled = true
        init(text: Binding<String>) { self.text = text }

        @objc func paste() {
            // Read only after the user explicitly presses Paste; never on appearance.
            guard isEnabled, text.wrappedValue.isEmpty, let value = UIPasteboard.general.string else { return }
            let pasted = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pasted.isEmpty { text.wrappedValue = pasted }
        }
    }
}

/// The system delivers text only after an explicit paste. No clipboard read is
/// needed when the form appears, and iOS can authorize the control directly.
private struct ServiceAPIKeyPasteControl: UIViewRepresentable {
    @Binding var text: String
    let accessibilityIdentifier: String

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        let traits = UITraitCollection(userInterfaceStyle: context.environment.colorScheme == .dark ? .dark : .light)
        configuration.displayMode = .labelOnly
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = context.environment.accountFlowTheme.map { UIColor($0.accent).resolvedColor(with: traits) }
            ?? UIColor.tertiarySystemFill.resolvedColor(with: traits)
        configuration.baseForegroundColor = context.environment.accountFlowTheme.map { UIColor($0.onAccent).resolvedColor(with: traits) }
            ?? UIColor.label.resolvedColor(with: traits)
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.accessibilityIdentifier = accessibilityIdentifier
        control.accessibilityLabel = L10n.text("粘贴")
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isEnabled = context.environment.isEnabled
        control.isUserInteractionEnabled = context.environment.isEnabled
        control.alpha = context.environment.isEnabled ? 1 : 0.4
        control.accessibilityLabel = L10n.text("粘贴")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPasteControl, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(width: max(64, size.width), height: max(44, size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UIPasteConfigurationSupporting {
        var text: Binding<String>
        var isEnabled = true
        var pasteConfiguration: UIPasteConfiguration? = UIPasteConfiguration(forAccepting: NSString.self)
        private var requestID: UUID?

        init(text: Binding<String>) { self.text = text }

        func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
            isEnabled && itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) }
        }

        func paste(itemProviders: [NSItemProvider]) {
            guard isEnabled, let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
            let request = UUID()
            requestID = request
            let previous = text.wrappedValue
            provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let value = object as? String else { return }
                let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor [weak self] in
                    // Don't overwrite typing or a newer paste while a provider loads.
                    guard let self, self.isEnabled, self.requestID == request,
                          self.text.wrappedValue == previous, !key.isEmpty else { return }
                    self.text.wrappedValue = key
                }
            }
        }
    }
}

/// Keep the same responder and selection when revealing a key. Secure entry
/// uses Apple's keyboard; explicit reveal allows the user's normal keyboard.
struct ServiceAPIKeyField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var revealsKey: Bool
    var accessibilityIdentifier = "local-service.api-key"
    var usesRoundedFont = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.keyboardType = .default
        field.returnKeyType = .done
        // API tokens are not account passwords. Password autofill also
        // interferes with the ordinary keyboard in the revealed state.
        field.textContentType = nil
        field.adjustsFontForContentSizeCategory = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityIdentifier = accessibilityIdentifier
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        field.isEnabled = context.environment.isEnabled
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        field.font = usesRoundedFont ? CurrencySymbolAlternates.font(
            size: UIFont.preferredFont(forTextStyle: .body, compatibleWith: field.traitCollection).pointSize,
            weight: .regular, rounded: true) : .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body, compatibleWith: field.traitCollection).pointSize,
            weight: .regular)
        field.tintColor = context.environment.accountFlowTheme.map { UIColor($0.controlTint) }
        field.textColor = context.environment.usesPaywallOnboardingStyle ? .white : CatfolioTheme.primaryTextUIColor
        if context.environment.usesPaywallOnboardingStyle {
            field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: UIColor.white.withAlphaComponent(0.4), .font: field.font as Any
            ])
        } else {
            field.attributedPlaceholder = nil
            field.placeholder = placeholder
        }
        if field.isSecureTextEntry == revealsKey {
            let selection = field.selectedTextRange
            field.isSecureTextEntry = !revealsKey
            field.text = text
            if let selection { field.selectedTextRange = selection }
            if field.isFirstResponder { field.reloadInputViews() }
        } else if field.text != text {
            field.text = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: uiView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
