import SwiftUI

/// Occupy the same text lines and plot geometry as the loaded hero. The panel,
/// range strip, handle and list keep their identity throughout loading.
struct ReturnsSourceHeaderPlaceholder: View {
    let theme: ReturnsSourceChartTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(" ")
                .appText(.footnote, weight: .medium)
                .overlay(alignment: .leading) { bar(width: 140, height: 12) }
            Text(" ")
                .font(Typography.number(size: 34, weight: .semibold))
                .overlay(alignment: .leading) { bar(width: 185, height: 28) }
            if theme == .losses {
                Text(" ")
                    .appText(.footnote, weight: .medium)
                    .overlay(alignment: .leading) { bar(width: 220, height: 12) }
                    .padding(.top, 4)
            }
        }
        .accessibilityLabel(L10n.text("正在准备历史数据"))
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.15))
            .frame(width: width, height: height)
    }
}

struct ReturnsSourcePlotPlaceholder: View {
    let appearanceID: String
    var body: some View {
        StandardLineChartSkeleton(axisWidth: 0, topInset: 4, bottomHeight: 0,
                                  seriesCount: 3, lineWidths: [1.5, 1.5, 1.5],
                                  appearanceID: appearanceID, showsAxis: false)
            .accessibilityHidden(true)
    }
}

struct ReturnsSourceRowsPlaceholder: View {
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        if let errorMessage {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.message(errorMessage)).appText(.callout)
                Button(L10n.text("重试"), action: retry).buttonStyle(.bordered)
            }
        } else {
            VStack(spacing: 12) {
                ForEach(0..<6) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6).frame(width: 20, height: 20)
                        RoundedRectangle(cornerRadius: 5).frame(width: 90, height: 14)
                        Spacer()
                        RoundedRectangle(cornerRadius: 5).frame(width: 70, height: 14)
                    }
                    .frame(height: 54)
                }
            }
            .foregroundStyle(.white.opacity(0.12))
            .accessibilityHidden(true)
        }
    }
}
