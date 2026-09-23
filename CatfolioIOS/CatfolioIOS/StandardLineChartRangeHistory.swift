import Foundation

/// The real observations available to a range transition. A camera change
/// may reveal either window, but must not invent values outside its history.
struct StandardLineChartRangeHistory {
    let points: [StandardLineChartPoint]

    init(from old: [StandardLineChartPoint], to new: [StandardLineChartPoint]) {
        var byDate: [Date: StandardLineChartPoint] = [:]
        byDate.reserveCapacity(old.count + new.count)
        for point in old { byDate[point.date] = point }
        // A refreshed observation at a shared date belongs to the new range.
        for point in new { byDate[point.date] = point }
        points = byDate.values.sorted { $0.date < $1.date }
    }

    /// Returns only the visible real polyline. A cut through an existing
    /// segment gets its linearly interpolated boundary point; a window beyond
    /// the first or last observation never gets a fabricated flat extension.
    func samples(from start: Date, to end: Date) -> [StandardLineChartPoint] {
        guard start < end, let first = points.first, let last = points.last,
              end >= first.date, start <= last.date else { return [] }

        let visibleStart = max(start, first.date)
        let visibleEnd = min(end, last.date)
        let firstIndex = lowerBound(visibleStart)
        let endIndex = upperBound(visibleEnd)
        var result: [StandardLineChartPoint] = []
        result.reserveCapacity(endIndex - firstIndex + 2)

        if firstIndex > 0, firstIndex < points.count,
           points[firstIndex].date > visibleStart {
            result.append(interpolate(at: visibleStart,
                                      between: points[firstIndex - 1], and: points[firstIndex]))
        }
        result.append(contentsOf: points[firstIndex..<endIndex])
        if endIndex > 0, endIndex < points.count,
           points[endIndex - 1].date < visibleEnd {
            result.append(interpolate(at: visibleEnd,
                                      between: points[endIndex - 1], and: points[endIndex]))
        }
        return result
    }

    private func lowerBound(_ date: Date) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].date < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func upperBound(_ date: Date) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].date <= date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func interpolate(
        at date: Date, between before: StandardLineChartPoint, and after: StandardLineChartPoint
    ) -> StandardLineChartPoint {
        let fraction = date.timeIntervalSince(before.date)
            / after.date.timeIntervalSince(before.date)
        return StandardLineChartPoint(date: date,
                                      value: before.value + (after.value - before.value) * fraction)
    }
}
