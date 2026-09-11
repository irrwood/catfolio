"""Focused regression coverage for the iOS volume-profile presentation rules."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"
SOURCE = ROOT / "VolumeProfileView.swift"


class VolumeProfilePresentationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
    def test_interpretation_and_currency_rules_execute_in_swift(self):
        source = SOURCE.read_text()
        rules = source[source.index("enum VolumeProfileInterpretation {"):
                       source.index("private struct VolumePriceChart")]
        harness = r'''
import Foundation
''' + rules + r'''
@main struct Tests {
    static func main() {
        func result(_ quote: Double, _ low: Double = 90, _ high: Double = 110,
                    _ poc: Double? = 100, cost: Double? = nil) -> VolumeProfileInterpretation.Result {
            VolumeProfileInterpretation.result(
                sessions: 160,
                quote: quote,
                valueAreaLow: low,
                valueAreaHigh: high,
                pointOfControl: poc,
                cost: cost
            )
        }

        precondition(result(89).pricePosition == .below)
        precondition(result(111).pricePosition == .above)
        precondition(result(90).pricePosition == .inside, "Lower bound must be inclusive")
        precondition(result(110).pricePosition == .inside, "Upper bound must be inclusive")
        precondition(result(101).isNearPointOfControl)
        precondition(!result(103).isNearPointOfControl)

        let parity = result(100, cost: 101)
        precondition(parity.costPosition == .aligned, "One-percent parity rule must be inclusive")
        let profit = result(100, cost: 84.6)
        precondition(profit.costPosition == .belowCurrent)
        precondition(abs((profit.costDifferencePercent ?? 0) - 15.4) < 0.0001)
        precondition(profit.text.contains("15.4%"))
        let loss = result(100, cost: 108.2)
        precondition(loss.costPosition == .aboveCurrent)
        precondition(abs((loss.costDifferencePercent ?? 0) - 8.2) < 0.0001)

        precondition(result(.nan).pricePosition == .unavailable)
        precondition(result(100, 100, 100).pricePosition == .unavailable)
        precondition(result(100, cost: nil).costPosition == .unavailable)
        precondition(!result(100, cost: nil).text.contains("持仓成本"))

        let rates: [String: Double] = ["GBP": 1.346, "GBX": 0.01346, "USD": 1]
        let gbp = VolumeProfileInterpretation.convertedPrice(
            123,
            from: "gbx",
            to: "GBP",
            usdRate: { rates[$0] }
        )
        precondition(abs((gbp ?? 0) - 1.23) < 0.0001)
        precondition(VolumeProfileInterpretation.convertedPrice(
            100,
            from: nil,
            to: "USD",
            usdRate: { rates[$0] }
        ) == nil)
        precondition(VolumeProfileInterpretation.convertedPrice(
            100,
            from: "UNKNOWN",
            to: "USD",
            usdRate: { rates[$0] }
        ) == nil)
        precondition(VolumeProfileInterpretation.convertedPrice(
            0,
            from: "USD",
            to: "USD",
            usdRate: { rates[$0] }
        ) == nil)

        func tails(_ bins: [(priceLow: Double, priceHigh: Double, volume: Double)])
            -> VolumeProfileInterpretation.TailPresence {
            VolumeProfileInterpretation.tailPresence(
                bins: bins,
                valueAreaLow: 90,
                valueAreaHigh: 110
            )
        }
        precondition(tails([(110, 115, 3)]).hasUpper && !tails([(110, 115, 3)]).hasLower)
        precondition(!tails([(85, 90, 3)]).hasUpper && tails([(85, 90, 3)]).hasLower)
        let both = tails([(85, 90, 3), (90, 110, 8), (110, 115, 2)])
        precondition(both.hasUpper && both.hasLower)
        let none = tails([(90, 100, 3), (100, 110, 8)])
        precondition(!none.hasUpper && !none.hasLower)
        let zeroVolumeTails = tails([(85, 90, 0), (90, 110, 8), (110, 115, 0)])
        precondition(!zeroVolumeTails.hasUpper && !zeroVolumeTails.hasLower)
        let fullRangeMain = tails([(90, 110, 8)])
        precondition(!fullRangeMain.hasUpper && !fullRangeMain.hasLower)
        precondition(tails([(109.999, 110.001, 0.01)]).hasUpper, "A real narrow tail remains data-driven")

        let narrowHandle = VolumeProfileInterpretation.curveVerticalHandle(distance: 0.3)
        precondition(abs(narrowHandle - 0.1) < 0.000_001)
        precondition(narrowHandle >= 0 && narrowHandle <= 0.3)
        precondition(VolumeProfileInterpretation.curveVerticalHandle(distance: -1) == 0)

        let exactMain = VolumeProfileInterpretation.continuousSlices(
            bins: [(90, 110, 8)], lowerBound: 90, upperBound: 110
        )
        precondition(exactMain == [.init(priceLow: 90, priceHigh: 110, volume: 8)])
        let connected = VolumeProfileInterpretation.continuousSlices(
            bins: [(90, 95, 5), (95, 100, 0), (100, 105, 4), (107, 110, 3)],
            lowerBound: 90,
            upperBound: 110
        )
        precondition(connected.count == 5, "A missing interval receives one zero-volume bridge")
        precondition(connected.map(\.volume) == [5, 0, 4, 0, 3])
        precondition(connected[3] == .init(priceLow: 105, priceHigh: 107, volume: 0))
        let extended = VolumeProfileInterpretation.continuousSlices(
            bins: [(90, 110, 8)], lowerBound: 80, upperBound: 120
        )
        precondition(extended == [
            .init(priceLow: 80, priceHigh: 90, volume: 0),
            .init(priceLow: 90, priceHigh: 110, volume: 8),
            .init(priceLow: 110, priceHigh: 120, volume: 0),
        ], "Out-of-range rendering anchors must not invent volume")
        let crossedMain = VolumeProfileInterpretation.continuousSlices(
            bins: [(88, 92, 5)], lowerBound: 90, upperBound: 110
        )
        let crossedTail = VolumeProfileInterpretation.continuousSlices(
            bins: [(88, 92, 5)], lowerBound: 88, upperBound: 90
        )
        precondition(crossedMain[0].priceLow == 90 && crossedMain[0].priceHigh == 92)
        precondition(crossedTail[0].priceLow == 88 && crossedTail[0].priceHigh == 90)
        precondition(VolumeProfileInterpretation.constrainedCornerRadius(
            height: 2, topWidth: 100, bottomWidth: 100
        ) == 1)
        precondition(VolumeProfileInterpretation.constrainedCornerRadius(
            height: 20, topWidth: 0.5, bottomWidth: 100
        ) == 0.25)
        print("Volume profile interpretation checks passed")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="catfolio-volume-profile-") as folder:
            fixture = Path(folder) / "VolumeProfileRules.swift"
            fixture.write_text(harness)
            executable = Path(folder) / "checks"
            compile_result = subprocess.run(
                ["swiftc", "-parse-as-library", str(fixture), "-o", str(executable)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            subprocess.run([str(executable)], check=True, capture_output=True, text=True)

    def test_chart_uses_real_bins_wide_bands_and_wrapping_copy(self):
        source = SOURCE.read_text()
        plot = source[source.index("private struct VolumeDistributionPlot"):]
        chart = source[source.index("private struct VolumePriceChart"):
                       source.index("private struct VolumeDistributionPlot")]

        self.assertIn("x += 30", plot)
        self.assertIn("lineWidth: 11", plot)
        self.assertIn("volumeProfileTailBlue", plot)
        self.assertIn("continuousSlices(", plot)
        self.assertIn("tailRegions", plot)
        self.assertIn("actualProfileRegion", plot)
        self.assertIn("volumeProfileExtensionBlue", plot)
        self.assertIn("layer.clip(to: silhouette)", plot)
        self.assertIn("max(4, plotWidth * CGFloat(displayValues[index]))", plot)
        self.assertNotIn("drawableRuns", plot)
        self.assertNotIn("visualGaps", plot)
        self.assertNotIn("var bands:", plot)
        self.assertIn("path.boundingRect", plot)
        self.assertNotIn("let topVerticalHandle = max(2", plot)
        self.assertNotIn("let bottomVerticalHandle = max(2", plot)
        self.assertNotIn("let verticalHandle = max(1", plot)
        self.assertNotIn("Path(roundedRect:", plot)
        self.assertIn("let valueAreaHigh: Double", plot)
        self.assertIn("let valueAreaLow: Double", plot)
        self.assertNotIn("0.20 + value", plot)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", chart)
        self.assertNotIn(".lineLimit(1)", chart)
        self.assertNotIn(".frame(height: 410", chart)

    def test_52_week_pressed_tick_keeps_its_original_fill_color(self):
        source = SOURCE.read_text()
        range_view = source[source.index("private struct FiftyTwoWeekRange"):
                            source.index("enum VolumeProfileInterpretation")]

        self.assertIn("let isActiveTick = isCurrent || isSelected", range_view)
        self.assertIn("if isCurrent {\n                Capsule().fill(performanceColor)", range_view)
        self.assertNotIn("if isActiveTick {\n                Capsule().fill(performanceColor)", range_view)
        self.assertIn("} else if isHighlighted {", range_view)
        self.assertIn("Capsule().fill(inactiveTickColor)", range_view)

    def test_52_week_pressed_tick_pushes_neighboring_ticks_with_spring_motion(self):
        source = SOURCE.read_text()
        range_view = source[source.index("private struct FiftyTwoWeekRange"):
                            source.index("enum VolumeProfileInterpretation")]

        self.assertIn("private let selectedPushPadding: CGFloat = 2", range_view)
        self.assertIn("let selectedSlotWidth = currentTickWidth + selectedPushPadding * 2", range_view)
        self.assertIn("let selectedExtraWidth = hasSeparateSelection ? selectedSlotWidth - tickWidth : 0", range_view)
        self.assertIn("+ precedingSelectedExtra", range_view)
        self.assertIn(".spring(response: 0.24, dampingFraction: 0.72", range_view)
        self.assertGreaterEqual(range_view.count("selectedIndex: nil"), 2)
        self.assertNotIn("Canvas { context, canvasSize in", range_view)

    def test_52_week_key_markers_snap_and_use_a_larger_bubble(self):
        source = SOURCE.read_text()
        range_view = source[source.index("private struct FiftyTwoWeekRange"):
                            source.index("enum VolumeProfileInterpretation")]

        self.assertIn("private let specialMarkerSnapRadius: CGFloat = 12", range_view)
        self.assertIn("let specialIndices = [currentIndex, startIndex]", range_view)
        self.assertIn("nearestSpecial.distance <= specialMarkerSnapRadius", range_view)
        self.assertIn(".font(.system(size: 12, weight: .semibold", range_view)
        self.assertIn(".padding(.horizontal, 12)", range_view)
        self.assertIn(".frame(height: 30)", range_view)
        self.assertIn("let inset: CGFloat = 72", range_view)

    def test_52_week_light_mode_only_current_tick_can_cast_a_glow(self):
        source = SOURCE.read_text()
        range_view = source[source.index("private struct FiftyTwoWeekRange"):
                            source.index("enum VolumeProfileInterpretation")]

        self.assertIn("private var inactiveTickGlowColor: Color", range_view)
        self.assertIn("let usesVisibleGlow = showsGlow && (isCurrent || colorScheme == .dark)", range_view)
        self.assertIn("isHighlighted ? performanceGlowColor : inactiveTickGlowColor", range_view)
        self.assertIn("radius: usesVisibleGlow ? (isCurrent ? 8 : 5) : 0", range_view)


if __name__ == "__main__":
    unittest.main()
