"""Exercise the real Swift price merge and the header/selection wiring."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS/CatfolioIOS"


def test_latest_price():
    models = (ROOT / "Models.swift").read_text()
    definitions = models[models.index("struct SecurityPriceHistory:"):models.index("struct SecurityTrade:")]
    codec = models[models.index("enum DayDateCodec {"):]
    # DayDateCodec is the last declaration in this file today.
    depth = 0
    for i, c in enumerate(codec):
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                codec = codec[:i + 1]
                break
    script = "import Foundation\nstruct SecurityTrade: Equatable {}\n" + definitions + codec + r'''
func minute(_ day: String, _ price: Double) -> SecurityPricePoint {
    let date = DayDateCodec.date(from: day)!.addingTimeInterval(15 * 3600)
    return .init(dateText: String(Int(date.timeIntervalSince1970)), close: price, timestamp: date)
}
func history(_ daily: [SecurityPricePoint], _ minutes: [SecurityPricePoint]) -> SecurityPriceHistory {
    .init(ticker: "TEST", currency: "USD", points: daily, intradayPoints: minutes, trades: [])
}
let daily: [SecurityPricePoint] = [.init(dateText: "2026-09-04", close: 100),
                                  .init(dateText: "2026-09-07", close: 110)]
let current = history(daily, [minute("2026-09-08", 120)])
precondition(current.latestAvailablePrice == 120)
precondition(current.chartDailyPoints.last?.dateText == "2026-09-08")
precondition(current.chartDailyPoints.count == 3)
precondition(current.points.last?.close == 110) // previous-close baseline is not overwritten
let sameDay = history(daily, [minute("2026-09-07", 115)])
precondition(sameDay.chartDailyPoints.count == 2)
precondition(sameDay.latestAvailablePrice == 115)
let stale = history(daily, [minute("2026-09-04", 90)])
precondition(stale.latestAvailablePrice == 110)
let weekend = history([daily[0]], [minute("2026-09-04", 105)])
precondition(weekend.chartDailyPoints.last?.dateText == "2026-09-04") // no invented weekend quote
precondition(history(daily, []).latestAvailablePrice == 110)
precondition(history(daily, [minute("2026-09-08", .nan)]).latestAvailablePrice == 110)
precondition(history([], []).latestAvailablePrice == nil)
print("PASS: latest-price merge, same-day update, stale protection, weekend, missing/invalid minute quotes")
'''
    subprocess.run(["swift", "-"], input=script, text=True, check=True)


def test_header_and_range_wiring():
    view = (ROOT / "VolumeProfileView.swift").read_text()
    service = (ROOT / "LocalServices.swift").read_text()
    header = view[view.index("HoldingDetailHeader("):view.index("if let priceHistory {")]
    assert "priceSelection?.price ?? priceHistory?.latestAvailablePrice" in header
    range_selection = view[view.index("private var rangeSelection:"):view.index("private func selection(for range:")]
    assert "price: nil" in range_selection
    assert "makeSelection(start: first, end: latest, price: nil" in range_selection
    assert "returnPercent: (end.price / start.price - 1) * 100" in view
    assert "let source = usesIntraday ? history.intradayPoints : history.chartDailyPoints" in view
    assert "price: point.price" in view  # historical touch still overrides
    assert "price: end.price" in view  # measurement still shows selected end point
    clear = view[view.index("private func clearInteraction()"):view.index("private struct SecurityPriceCostLegend")]
    assert "onSelectionChange(rangeSelection)" in clear
    assert "closes[end] = referencePrice / scale" not in service
    print("PASS: range changes only return; historical touch/end preserved; no stale reference overwrite")


if __name__ == "__main__":
    test_latest_price()
    test_header_and_range_wiring()
