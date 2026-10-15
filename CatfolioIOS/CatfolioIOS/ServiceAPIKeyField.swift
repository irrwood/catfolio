import SwiftUI
import UIKit

/// Keep the same responder and selection when revealing a key. Secure entry
/// uses Apple's keyboard; explicit reveal allows the user's normal keyboard.
struct ServiceAPIKeyField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var revealsKey: Bool
    var accessibilityIdentifier = "local-service.api-key"
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
        field.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body, compatibleWith: field.traitCollection).pointSize,
            weight: .regular)
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
