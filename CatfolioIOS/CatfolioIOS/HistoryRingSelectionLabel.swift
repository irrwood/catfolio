import SwiftUI

/// Reserve the tallest heading before scrubbing, so wrapping a selected name
/// cannot move the ring and change the angle under the user's finger.
struct HistoryRingSelectionLabel: View {
    struct Choice {
        let title: String
        let percentage: String
    }

    let title: String
    let percentage: String?
    let choices: [Choice]

    var body: some View {
        ZStack(alignment: .topLeading) {
            heading(title: L10n.text("比例"), percentage: nil)
            ForEach(choices.indices, id: \.self) { index in
                heading(title: choices[index].title, percentage: choices[index].percentage)
            }
        }
        .hidden()
        .accessibilityHidden(true)
        .overlay(alignment: .topLeading) {
            heading(title: title, percentage: percentage)
        }
        .contentShape(Rectangle())
    }

    private func heading(title: String, percentage: String?) -> some View {
        HStack(spacing: SettingsTemplate.iconSpacing) {
            Text(title)
                .appText(.subheading, weight: .medium)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let percentage {
                FinancialText(percentage)
                    .appNumber(.callout, weight: .semibold)
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
