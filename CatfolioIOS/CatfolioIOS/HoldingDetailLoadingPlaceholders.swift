import SwiftUI
import UIKit
import Observation

/// Shared with the live volume section so arrival does not replace one
/// loading layout with a different loading layout.
struct HoldingVolumeProfileLoadingPlaceholder: View {
    let ticker: String

    var body: some View {
        HoldingDetailSectionCard(title: L10n.text("Volume Profile")) {
            VStack(alignment: .leading, spacing: 16) {
                ChartShapeSkeleton(layout: .horizontalBars, appearanceID: "volume-profile|\(ticker)")
                    .frame(height: 184)
                ChartSkeletonShape(height: 12)
            }
        }
    }
}


struct HoldingDetailLowerLoadingPlaceholder: View {
    let ticker: String
    let showsPosition: Bool

    var body: some View {
        VStack(spacing: HoldingDetailCardStyle.spacing) {
            HoldingVolumeProfileLoadingPlaceholder(ticker: ticker)
            VStack(alignment: .leading, spacing: 8) {
                ChartSkeletonShape(width: 130, height: 19)
                    .padding([.horizontal, .top], HoldingDetailCardStyle.contentInset)
                ChartShapeSkeleton(layout: .horizontalBars, appearanceID: "options-oi|\(ticker)")
                    .padding(.horizontal, 20)
                    .frame(height: 397)
            }
            .holdingDetailCard()
            if showsPosition {
                VStack(alignment: .leading, spacing: 20) {
                    ChartSkeletonShape(width: 100, height: 19)
                    ForEach(0..<4, id: \.self) { _ in
                        HStack {
                            ChartSkeletonShape(width: 82, height: 12)
                            Spacer()
                            ChartSkeletonShape(width: 64, height: 12)
                        }
                    }
                }
                .padding(HoldingDetailCardStyle.contentInset)
                .holdingDetailCard()
            }
        }
        .padding(.horizontal, HoldingDetailCardStyle.pageInset)
        .padding(.top, 24)
        .padding(.bottom, 72)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("正在加载个股详情"))
        .accessibilityIdentifier("holding-detail-lower-loading")
    }
}

struct HoldingDetailLoadingPlaceholder: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    private var skeletonColor: Color {
        CatfolioTheme.skeletonFill
    }

    private var skeletonSurface: Color {
        CatfolioTheme.subtleFill
    }

    private var skeletonCardBackground: Color {
        CatfolioTheme.surface(for: colorScheme)
    }

    private var accountSkeletonColor: Color {
        CatfolioTheme.skeletonFill
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(skeletonColor)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 7) {
                        skeletonBar(width: 64, height: 14)
                        HStack(spacing: 8) {
                            skeletonBar(width: 59, height: 10)
                            skeletonBar(width: 40, height: 10)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 7) {
                        skeletonBar(width: 70, height: 14)
                        skeletonBar(width: 82, height: 10)
                    }
                }
                .frame(height: 64)
                .padding(.horizontal, 20)

                StandardLineChartSkeleton(
                    leadingLineOverflow: 30,
                    trailingEndpointInset: 9,
                    lineWidths: [2]
                )
                    .frame(height: SecurityPriceChartState.plotHeight)

                ChartTimeRangePickerSkeleton()
                    .frame(height: 62)

                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 7) {
                                skeletonBar(
                                    width: index == 1 ? 53 : (index == 2 ? 24 : 28),
                                    height: 11,
                                    color: accountSkeletonColor
                                )
                                skeletonBar(width: 68, height: 11, color: accountSkeletonColor)
                            }
                            .padding(.horizontal, 24)
                            .frame(minWidth: 116, minHeight: 64, alignment: .leading)
                            .background(skeletonSurface, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(height: 92)
            }
            .padding(.top, 15)

            LazyVStack(spacing: 64) {
                volumeProfileSkeleton
                fiftyTwoWeekSkeleton
                dataSkeleton
                financialSkeleton
                predictionMarketsSkeleton
            }
            .padding(.horizontal, HoldingDetailCardStyle.pageInset)
            .padding(.top, 40)
            .padding(.bottom, 72)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("正在加载个股详情"))
    }

    private var volumeProfileSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    skeletonBar(width: 142, height: 15)
                    Spacer()
                    skeletonBar(width: 89, height: 12)
                }
                .frame(height: 23)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(skeletonSurface)

                    VStack(alignment: .leading) {
                        skeletonBar(width: 66, height: 10, color: accountSkeletonColor)
                        Spacer()
                        skeletonBar(width: 56, height: 10, color: accountSkeletonColor)
                    }
                    .padding(10)
                }
                .frame(height: 303)
            }

            VStack(alignment: .leading, spacing: 6) {
                Capsule()
                    .fill(skeletonColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
                Capsule()
                    .fill(skeletonColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
            }
            .frame(height: 48, alignment: .center)
        }
        .frame(height: 410, alignment: .top)
    }

    private var fiftyTwoWeekSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                skeletonBar(width: 355, height: 15)
            }
            .frame(height: 23, alignment: .center)

            HStack(alignment: .center, spacing: 3.1) {
                ForEach(0..<51, id: \.self) { index in
                    Capsule()
                        .fill(skeletonColor)
                        .frame(width: index == 25 ? 7 : 4, height: index == 25 ? 110 : 98)
                }
            }
            .frame(height: 110)
            .padding(.top, 20)

            HStack {
                skeletonBar(width: 82, height: 11)
                Spacer()
                skeletonBar(width: 90, height: 11)
            }
            .frame(height: 16)
            .padding(.top, 7)
        }
        .frame(height: 176, alignment: .top)
    }

    private var dataSkeleton: some View {
        let rows: [(HoldingDataIcon, CGFloat, CGFloat)] = [
            (.value, 45, 40),
            (.returnValue, 56, 30),
            (.cost, 36, 30),
            (.fxImpact, 72, 49),
            (.proportion, 93, 46),
            (.unrealisedProfitLoss, 117, 143),
        ]

        return VStack(alignment: .leading, spacing: 0) {
            skeletonBar(width: 46, height: 15)
                .frame(height: 23, alignment: .center)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    dataSkeletonRow(
                        icon: row.0,
                        labelWidth: row.1,
                        valueWidth: row.2,
                        isCombinedValue: index == rows.count - 1,
                        isAlternating: index.isMultiple(of: 2) == false
                    )
                }
            }
            .padding(.top, 20)
        }
        .frame(height: 307, alignment: .top)
    }

    private var financialSkeleton: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                skeletonBar(width: 79, height: 14)
                VStack(alignment: .leading, spacing: 6) {
                    skeletonBar(width: 237, height: 10)
                    skeletonBar(width: 184, height: 10)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(skeletonColor)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 105, maxHeight: 105, alignment: .leading)
        .background(skeletonCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(skeletonColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var predictionMarketsSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                skeletonBar(width: 166, height: 14)
                Spacer(minLength: 8)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(skeletonColor)
                    .frame(width: 24, height: 24)
            }
            .frame(height: 24)

            VStack(spacing: 20) {
                ForEach(0..<5, id: \.self) { index in
                    predictionMarketRowSkeleton(index: index)
                }
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        // The real card no longer ends in a disclaimer row (it moved to the
        // page footer), so neither does its placeholder: 563 less that row.
        .frame(maxWidth: .infinity, minHeight: 507, maxHeight: 507, alignment: .topLeading)
        .background(skeletonCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(skeletonColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func dataSkeletonRow(
        icon: HoldingDataIcon,
        labelWidth: CGFloat,
        valueWidth: CGFloat,
        isCombinedValue: Bool,
        isAlternating: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Group {
                if let assetName = icon.assetName {
                    Image(assetName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                } else {
                    Image(systemName: icon.systemName)
                        .font(.system(size: icon.pointSize, weight: .regular))
                }
            }
            .foregroundStyle(skeletonColor)
            .frame(width: 24, height: 24)

            skeletonBar(width: labelWidth, height: 10)

            Spacer(minLength: 8)

            if isCombinedValue {
                HStack(spacing: 8) {
                    skeletonBar(width: 81, height: 10)
                    Circle()
                        .fill(skeletonColor)
                        .frame(width: 4, height: 4)
                    skeletonBar(width: 42, height: 10)
                }
            } else {
                skeletonBar(width: valueWidth, height: 10)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 44)
        .background(
            isAlternating ? skeletonSurface : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func predictionMarketRowSkeleton(index: Int) -> some View {
        let statWidths: [CGFloat] = [47, 53, 47, 47, 47]

        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    skeletonBar(width: 260, height: 10)
                    skeletonBar(width: 260, height: 10)
                }
                .frame(height: 36, alignment: .top)

                HStack(spacing: 8) {
                    skeletonBar(width: 63, height: 9)
                    Circle()
                        .fill(skeletonColor)
                        .frame(width: 4, height: 4)
                    skeletonBar(width: 70, height: 9)
                }
                .frame(height: 16)
            }
            .frame(width: 260, alignment: .leading)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                skeletonBar(width: statWidths[index], height: 10)
                skeletonBar(width: index == 1 ? 19 : 23, height: 9)
            }
            .frame(height: 38, alignment: .topTrailing)
        }
        .frame(height: 60, alignment: .top)
    }

    private func skeletonBar(width: CGFloat, height: CGFloat, color: Color? = nil) -> some View {
        Capsule()
            .fill(color ?? skeletonColor)
            .frame(width: width, height: height)
    }
}

// MARK: Prefetch
