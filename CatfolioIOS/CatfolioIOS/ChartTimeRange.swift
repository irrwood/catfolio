import ImageIO
import Observation
import SwiftUI
import UIKit

/// A compact chart range selector with a single floating selected capsule.
/// Unselected choices remain plain text so the control does not read as a
/// traditional segmented bar.
enum ChartTimeRangePickerMetrics {
    static let horizontalInset: CGFloat = 16
    static let itemWidth: CGFloat = 44
    static let itemHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 10
}

/// The single time-window vocabulary used by every chart in the app.
/// Tapping a selected grouped slot advances to its next range.
enum ChartTimeRange: String, CaseIterable, Identifiable {
    case oneDay = "1D"
    case threeDays = "3D"
    case oneWeek = "1W"
    case oneMonth = "1M"
    case twoMonths = "2M"
    case threeMonths = "3M"
    case yearToDate = "YTD"
    case sixMonths = "6M"
    case oneYear = "1Y"
    case twoYears = "2Y"
    case threeYears = "3Y"
    case fiveYears = "5Y"
    case maximum = "MAX"

    var id: String { rawValue }
    var title: String { L10n.label(rawValue) }

    static let choiceGroups: [[ChartTimeRange]] = [
        // A tap on the selected slot steps through its group: 1W → 1D → 3D,
        // 1M → 2M → 3M, 1Y → 2Y → 3Y.
        [.oneWeek, .oneDay, .threeDays],
        [.oneMonth, .twoMonths, .threeMonths],
        [.yearToDate, .sixMonths],
        [.oneYear, .twoYears, .threeYears],
        // Paired like every other slot. MAX was the only singleton, so it
        // was the one place a tap did nothing.
        [.maximum, .fiveYears],
    ]

    func includes(
        _ date: Date,
        through lastDate: Date,
        previousTradingDate: Date? = nil,
        calendar: Calendar = financeCalendar
    ) -> Bool {
        let start: Date?
        switch self {
        case .oneDay:
            start = previousTradingDate ?? lastDate
        case .threeDays:
            start = calendar.date(byAdding: .day, value: -3, to: lastDate)
        case .oneWeek:
            start = calendar.date(byAdding: .day, value: -7, to: lastDate)
        case .oneMonth:
            start = calendar.date(byAdding: .month, value: -1, to: lastDate)
        case .twoMonths:
            start = calendar.date(byAdding: .month, value: -2, to: lastDate)
        case .threeMonths:
            start = calendar.date(byAdding: .month, value: -3, to: lastDate)
        case .yearToDate:
            start = calendar.date(from: calendar.dateComponents([.year], from: lastDate))
        case .sixMonths:
            start = calendar.date(byAdding: .month, value: -6, to: lastDate)
        case .oneYear:
            start = calendar.date(byAdding: .year, value: -1, to: lastDate)
        case .twoYears:
            start = calendar.date(byAdding: .year, value: -2, to: lastDate)
        case .threeYears:
            start = calendar.date(byAdding: .year, value: -3, to: lastDate)
        case .fiveYears:
            start = calendar.date(byAdding: .year, value: -5, to: lastDate)
        case .maximum:
            start = nil
        }
        return start.map { date >= $0 } ?? true
    }

    static var financeCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

/// A compact Torph-style label transition for the grouped range picker.
/// Characters keep their place-value slot, so unchanged glyphs stay still
/// while changed glyphs travel vertically and cross-fade. The outer picker
/// owns a fixed hit target, leaving this HStack free to animate its intrinsic
/// width when a label changes between values such as `YTD` and `6M`.
struct ChartTimeRangeMorphingLabel: View {
    @Environment(\.locale) private var appLocale
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var characters: [(offset: Int, element: Character)] {
        Array(text.enumerated())
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(characters, id: \.offset) { item in
                Text(String(item.element))
                    .id("\(item.offset)-\(item.element)")
                    .transition(characterTransition)
            }
        }
        .animation(textAnimation, value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var characterTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .offset(y: 5).combined(with: .opacity),
            removal: .offset(y: -5).combined(with: .opacity)
        )
    }

    private var textAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.32, dampingFraction: 0.82, blendDuration: 0.06)
    }
}

struct ChartTimeRangePicker: View {
    @Environment(\.locale) private var appLocale
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Binding var selection: ChartTimeRange
    var choiceGroups = ChartTimeRange.choiceGroups
    var isDisabled = false
    var usesBrightSelectedBackground = false
    /// On a tinted field — the gain-sources hero — the strip carries the
    /// field's colour, so the selected range is a white pill with dark text
    /// in both schemes rather than the page's own fill.
    var isOnTintedField = false
    var isOnComparisonField = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choiceGroups.indices, id: \.self) { index in
                let group = choiceGroups[index]
                let choice = displayedChoice(in: group)
                let isSelected = group.contains(selection)
                Button {
                    select(group)
                } label: {
                    ChartTimeRangeMorphingLabel(text: choice.title)
                        .appText(.footnote, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(textColor(isSelected: isSelected))
                        .lineLimit(1)
                        .frame(
                            width: ChartTimeRangePickerMetrics.itemWidth,
                            height: ChartTimeRangePickerMetrics.itemHeight
                        )
                        .background {
                            if isSelected {
                                RoundedRectangle(
                                    cornerRadius: ChartTimeRangePickerMetrics.cornerRadius,
                                    style: .continuous
                                )
                                    .fill(selectedBackgroundColor)
                            }
                        }
                        .contentShape(RoundedRectangle(
                            cornerRadius: ChartTimeRangePickerMetrics.cornerRadius,
                            style: .continuous
                        ))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(accessibilityHint(for: group, displayedChoice: choice))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, ChartTimeRangePickerMetrics.horizontalInset)
        .disabled(isDisabled)
        // Fires on the change, so tapping the range already selected stays
        // silent — there is nothing for the tap to confirm.
        .sensoryFeedback(.selection, trigger: selection) { _, _ in hapticsEnabled }
        .opacity(isDisabled ? 0.55 : 1)
    }

    private func displayedChoice(in group: [ChartTimeRange]) -> ChartTimeRange {
        group.first(where: { $0 == selection }) ?? group[0]
    }

    private func select(_ group: [ChartTimeRange]) {
        guard let first = group.first else { return }
        guard let selectedIndex = group.firstIndex(of: selection) else {
            selection = first
            return
        }
        selection = group[(selectedIndex + 1) % group.count]
    }

    private func accessibilityHint(
        for group: [ChartTimeRange],
        displayedChoice: ChartTimeRange
    ) -> String {
        guard group.count > 1,
              let index = group.firstIndex(of: displayedChoice) else { return "" }
        let next = group[(index + 1) % group.count]
        return L10n.text("再次轻点切换到 \(next.title)")
    }

    private func textColor(isSelected: Bool) -> Color {
        if isOnComparisonField { return .white.opacity(isSelected ? 1 : 0.5) }
        if isOnTintedField {
            if isSelected { return Color(red: 0.10, green: 0.10, blue: 0.10) }
            return colorScheme == .dark ? Color.white.opacity(0.82) : Color.black.opacity(0.58)
        }
        if isSelected {
            return colorScheme == .light ? .black : .white
        }
        return .secondary
    }

    private var selectedBackgroundColor: Color {
        if isOnComparisonField { return .white.opacity(0.1) }
        if isOnTintedField { return .white }
        if usesBrightSelectedBackground, colorScheme == .light {
            return .white
        }
        return CatfolioTheme.subtleFill
    }
}

/// Geometry-matched loading state for the shared time-range picker. Keeping
/// this beside `ChartTimeRangePicker` prevents each chart screen from
/// inventing a different set of placeholder widths and selected-pill bounds.
struct ChartTimeRangePickerSkeleton: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    var itemCount = ChartTimeRange.choiceGroups.count
    var selectedIndex = 1

    private var skeletonColor: Color {
        CatfolioTheme.skeletonFill
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, itemCount), id: \.self) { index in
                ZStack {
                    if index == selectedIndex {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(skeletonColor.opacity(1.18))
                            .frame(width: 44, height: 30)
                    }

                    Capsule()
                        .fill(skeletonColor)
                        .frame(width: index == itemCount - 1 ? 23 : 14, height: 9)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
