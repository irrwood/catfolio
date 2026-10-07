import SwiftUI
import UIKit
import Observation

enum VolumeProfileInterpretation {
    /// Product rule: "near the POC" means no farther than 10% of the
    /// selected historical value area's width. This is a presentation rule,
    /// not a market or accounting standard.
    static let pointOfControlProximityFraction = 0.10

    /// Product rule: costs within 1% of the current quote are described as
    /// broadly aligned. This is deliberately centralized for copy consistency.
    static let costParityFraction = 0.01

    enum PricePosition: Equatable {
        case below
        case inside
        case above
        case unavailable
    }

    enum CostPosition: Equatable {
        case belowCurrent
        case aligned
        case aboveCurrent
        case unavailable
    }

    struct Result: Equatable {
        let text: String
        let pricePosition: PricePosition
        let costPosition: CostPosition
        let isNearPointOfControl: Bool
        let costDifferencePercent: Double?
    }

    struct TailPresence: Equatable {
        let hasUpper: Bool
        let hasLower: Bool
    }

    struct BinSlice: Equatable {
        let priceLow: Double
        let priceHigh: Double
        let volume: Double
    }

    static func tailPresence(
        bins: [(priceLow: Double, priceHigh: Double, volume: Double)],
        valueAreaLow: Double,
        valueAreaHigh: Double
    ) -> TailPresence {
        guard valueAreaLow.isFinite,
              valueAreaHigh.isFinite,
              valueAreaHigh > valueAreaLow else {
            return TailPresence(hasUpper: false, hasLower: false)
        }
        let validBins = bins.filter {
            $0.volume.isFinite
                && $0.volume > 0
                && $0.priceLow.isFinite
                && $0.priceHigh.isFinite
                && $0.priceHigh > $0.priceLow
        }
        return TailPresence(
            hasUpper: validBins.contains { $0.priceHigh > valueAreaHigh },
            hasLower: validBins.contains { $0.priceLow < valueAreaLow }
        )
    }

    static func curveVerticalHandle(distance: Double) -> Double {
        guard distance.isFinite, distance > 0 else { return 0 }
        return distance / 3
    }

    /// Builds one continuous price profile. Real zero-volume buckets are kept as
    /// zero-width anchors, and missing price intervals receive a synthetic
    /// zero-volume anchor. The renderer can therefore keep one silhouette and
    /// taper empty regions into a narrow visual neck instead of separate islands.
    static func continuousSlices(
        bins: [(priceLow: Double, priceHigh: Double, volume: Double)],
        lowerBound: Double,
        upperBound: Double
    ) -> [BinSlice] {
        guard lowerBound.isFinite,
              upperBound.isFinite,
              upperBound > lowerBound else { return [] }

        let sortedBins = bins.filter {
            $0.volume.isFinite
                && $0.volume >= 0
                && $0.priceLow.isFinite
                && $0.priceHigh.isFinite
                && $0.priceHigh > $0.priceLow
        }.sorted { ($0.priceLow + $0.priceHigh) < ($1.priceLow + $1.priceHigh) }

        var slices: [BinSlice] = []
        var previousHigh = lowerBound
        var hasPositiveVolume = false

        for bin in sortedBins {
            let clippedLow = max(bin.priceLow, lowerBound)
            let clippedHigh = min(bin.priceHigh, upperBound)
            guard clippedHigh > clippedLow else { continue }
            let tolerance = max(0.000_000_001, max(abs(previousHigh), abs(clippedLow)) * 0.000_000_001)
            if clippedLow > previousHigh + tolerance {
                slices.append(BinSlice(priceLow: previousHigh, priceHigh: clippedLow, volume: 0))
            }
            slices.append(BinSlice(priceLow: clippedLow, priceHigh: clippedHigh, volume: bin.volume))
            hasPositiveVolume = hasPositiveVolume || bin.volume > 0
            previousHigh = max(previousHigh, clippedHigh)
        }
        let trailingTolerance = max(
            0.000_000_001,
            max(abs(previousHigh), abs(upperBound)) * 0.000_000_001
        )
        if previousHigh < upperBound - trailingTolerance {
            slices.append(BinSlice(priceLow: previousHigh, priceHigh: upperBound, volume: 0))
        }
        return hasPositiveVolume ? slices : []
    }

    static func constrainedCornerRadius(
        height: Double,
        topWidth: Double,
        bottomWidth: Double
    ) -> Double {
        guard height.isFinite,
              topWidth.isFinite,
              bottomWidth.isFinite else { return 0 }
        return max(0, min(18, min(height / 2, min(topWidth / 2, bottomWidth / 2))))
    }

    static func result(
        sessions: Int,
        quote: Double,
        valueAreaLow: Double,
        valueAreaHigh: Double,
        pointOfControl: Double?,
        cost: Double?
    ) -> Result {
        guard quote.isFinite,
              quote > 0,
              valueAreaLow.isFinite,
              valueAreaHigh.isFinite,
              valueAreaHigh > valueAreaLow else {
            return Result(
                text: L10n.text("当前价格或主成交区数据暂不可用。"),
                pricePosition: .unavailable,
                costPosition: .unavailable,
                isNearPointOfControl: false,
                costDifferencePercent: nil
            )
        }

        let rawPeriod = sessions > 0 ? L10n.text("过去\(sessions)个交易日") : L10n.text("所选历史区间")
        let isEnglish = AppLanguage.currentIdentifier == "en"
        let period = isEnglish ? rawPeriod.prefix(1).lowercased() + String(rawPeriod.dropFirst()) : rawPeriod
        let sentenceSpace = isEnglish ? " " : ""
        let areaWidth = valueAreaHigh - valueAreaLow
        let isNearPointOfControl = pointOfControl.map { point in
            point.isFinite
                && point >= valueAreaLow
                && point <= valueAreaHigh
                && abs(quote - point) <= areaWidth * pointOfControlProximityFraction
        } ?? false

        let pricePosition: PricePosition
        var priceText: String
        if quote < valueAreaLow {
            pricePosition = .below
            priceText = L10n.text("当前价格低于\(period)的主要成交区域，说明市场相对于所选历史成交区域处于弱势位置。")
        } else if quote > valueAreaHigh {
            pricePosition = .above
            priceText = L10n.text("当前价格已高于\(period)的主要成交密集区，说明市场相对于所选历史成交区域处于较高位置。")
        } else {
            pricePosition = .inside
            priceText = L10n.text("当前价格位于\(period)的主成交区内")
            priceText += isNearPointOfControl
                ? sentenceSpace + L10n.text("，且接近成交峰值。")
                : (isEnglish ? "." : "。")
        }

        guard let cost, cost.isFinite, cost > 0 else {
            return Result(
                text: priceText,
                pricePosition: pricePosition,
                costPosition: .unavailable,
                isNearPointOfControl: isNearPointOfControl,
                costDifferencePercent: nil
            )
        }

        let differenceFraction = abs(cost - quote) / quote
        let differencePercent = differenceFraction * 100
        let costPosition: CostPosition
        let costText: String
        if differenceFraction <= costParityFraction {
            costPosition = .aligned
            costText = L10n.text("你的持仓成本与现价基本持平。")
        } else if cost < quote {
            costPosition = .belowCurrent
            costText = L10n.text("你的持仓成本低于现价\(percentageText(differencePercent))%，目前持仓处于盈利状态。")
        } else {
            costPosition = .aboveCurrent
            costText = L10n.text("你的持仓成本高于现价\(percentageText(differencePercent))%，当前持仓处于浮亏状态。")
        }

        return Result(
            text: "\(priceText)\(sentenceSpace)\(costText)",
            pricePosition: pricePosition,
            costPosition: costPosition,
            isNearPointOfControl: isNearPointOfControl,
            costDifferencePercent: differencePercent
        )
    }

    static func convertedPrice(
        _ value: Double,
        from sourceCurrency: String?,
        to targetCurrency: String?,
        usdRate: (String) -> Double?
    ) -> Double? {
        guard value.isFinite,
              value > 0,
              let source = normalizedCurrency(sourceCurrency),
              let target = normalizedCurrency(targetCurrency) else { return nil }
        guard source != target else { return value }
        guard let sourceRate = usdRate(source),
              let targetRate = usdRate(target),
              sourceRate.isFinite,
              targetRate.isFinite,
              sourceRate > 0,
              targetRate > 0 else { return nil }
        let converted = value * sourceRate / targetRate
        return converted.isFinite && converted > 0 ? converted : nil
    }

    private static func normalizedCurrency(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func percentageText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
