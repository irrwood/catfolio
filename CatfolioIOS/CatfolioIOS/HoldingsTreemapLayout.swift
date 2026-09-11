import Foundation
import CoreGraphics

/// Deterministic, allocation-light squarified treemap layout for portfolio holdings.
///
/// The returned frames fill `bounds`, and each frame's area is proportional to the
/// corresponding positive weight. Callers can inset the frames slightly when drawing
/// to create visual gutters without changing the layout calculation.
struct HoldingsTreemapLayout {
    struct Item: Equatable {
        let ticker: String
        let weight: Double

        init(ticker: String, weight: Double) {
            self.ticker = ticker
            self.weight = weight
        }
    }

    struct Tile: Equatable {
        /// Position of the item in the input array, useful when tickers are duplicated.
        let sourceIndex: Int
        let ticker: String
        let weight: Double
        let fraction: Double
        let frame: CGRect
    }

    /// Creates a squarified treemap for all finite, positive-weight items.
    ///
    /// Invalid or zero-weight items are omitted. Tiles are returned in descending weight
    /// order, except an optional final item anchored at the bottom-right corner. Its
    /// area still matches its weight. Equal weights keep their input order.
    static func layout(items: [Item], in bounds: CGRect, lastItemIndex: Int? = nil) -> [Tile] {
        guard isUsable(bounds) else { return [] }

        let weightedItems = items.enumerated()
            .filter { $0.element.weight.isFinite && $0.element.weight > 0 }
            .sorted { lhs, rhs in
                if (lhs.offset == lastItemIndex) != (rhs.offset == lastItemIndex) {
                    return rhs.offset == lastItemIndex
                }
                return lhs.element.weight == rhs.element.weight
                    ? lhs.offset < rhs.offset : lhs.element.weight > rhs.element.weight
            }

        guard let largestWeight = weightedItems.map({ $0.element.weight }).max() else { return [] }

        // Scaling by the largest weight prevents overflow when summing very large values.
        let scaledTotal = weightedItems.reduce(into: 0.0) { result, entry in
            result += entry.element.weight / largestWeight
        }
        guard scaledTotal.isFinite && scaledTotal > 0 else { return [] }

        let layoutBounds = LayoutRect(bounds)
        let totalArea = layoutBounds.width * layoutBounds.height
        guard totalArea.isFinite && totalArea > 0 else { return [] }

        let nodes = weightedItems.map { entry in
            let fraction = (entry.element.weight / largestWeight) / scaledTotal
            return Node(
                sourceIndex: entry.offset,
                ticker: entry.element.ticker,
                weight: entry.element.weight,
                fraction: fraction,
                area: totalArea * fraction
            )
        }

        var remainingBounds = layoutBounds
        var currentRow: [Node] = []
        var currentMetrics = RowMetrics()
        var tiles: [Tile] = []
        var nextIndex = 0
        currentRow.reserveCapacity(nodes.count)
        tiles.reserveCapacity(nodes.count)

        while nextIndex < nodes.count {
            let next = nodes[nextIndex]
            let shortSide = min(remainingBounds.width, remainingBounds.height)
            let candidateMetrics = currentMetrics.adding(next)

            if currentRow.isEmpty
                || candidateMetrics.worstAspectRatio(along: shortSide)
                    <= currentMetrics.worstAspectRatio(along: shortSide) {
                currentRow.append(next)
                currentMetrics = candidateMetrics
                nextIndex += 1
            } else {
                layout(
                    row: currentRow,
                    rowArea: currentMetrics.totalArea,
                    in: &remainingBounds,
                    output: &tiles
                )
                currentRow.removeAll(keepingCapacity: true)
                currentMetrics = RowMetrics()
            }
        }

        if !currentRow.isEmpty {
            layout(
                row: currentRow,
                rowArea: currentMetrics.totalArea,
                in: &remainingBounds,
                output: &tiles
            )
        }

        return tiles
    }

    private struct Node {
        let sourceIndex: Int
        let ticker: String
        let weight: Double
        let fraction: Double
        let area: Double
    }

    private struct RowMetrics {
        var totalArea = 0.0
        var smallestArea = Double.infinity
        var largestArea = 0.0

        func adding(_ node: Node) -> RowMetrics {
            RowMetrics(
                totalArea: totalArea + node.area,
                smallestArea: min(smallestArea, node.area),
                largestArea: max(largestArea, node.area)
            )
        }

        func worstAspectRatio(along side: Double) -> Double {
            guard side.isFinite,
                  side > 0,
                  totalArea > 0,
                  smallestArea > 0 else {
                return .infinity
            }

            let sideSquared = side * side
            let totalSquared = totalArea * totalArea
            return max(
                sideSquared * largestArea / totalSquared,
                totalSquared / (sideSquared * smallestArea)
            )
        }
    }

    private struct LayoutRect {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = Double(rect.minX)
            y = Double(rect.minY)
            width = Double(rect.width)
            height = Double(rect.height)
        }

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var maxX: Double { x + width }
        var maxY: Double { y + height }
    }

    private static func isUsable(_ bounds: CGRect) -> Bool {
        !bounds.isNull
            && !bounds.isInfinite
            && bounds.minX.isFinite
            && bounds.minY.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
    }

    private static func layout(
        row: [Node],
        rowArea: Double,
        in bounds: inout LayoutRect,
        output: inout [Tile]
    ) {
        guard !row.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        if bounds.width >= bounds.height {
            layoutVerticalStrip(
                row: row,
                rowArea: rowArea,
                in: &bounds,
                output: &output
            )
        } else {
            layoutHorizontalStrip(
                row: row,
                rowArea: rowArea,
                in: &bounds,
                output: &output
            )
        }
    }

    private static func layoutVerticalStrip(
        row: [Node],
        rowArea: Double,
        in bounds: inout LayoutRect,
        output: inout [Tile]
    ) {
        let stripWidth = min(bounds.width, rowArea / bounds.height)
        guard stripWidth.isFinite, stripWidth > 0 else { return }

        var cursorY = bounds.y
        for (index, node) in row.enumerated() {
            let height = index == row.indices.last
                ? max(0, bounds.maxY - cursorY)
                : min(max(0, node.area / stripWidth), bounds.maxY - cursorY)

            appendTile(
                node,
                frame: LayoutRect(x: bounds.x, y: cursorY, width: stripWidth, height: height),
                to: &output
            )
            cursorY += height
        }

        bounds.x += stripWidth
        bounds.width = max(0, bounds.width - stripWidth)
    }

    private static func layoutHorizontalStrip(
        row: [Node],
        rowArea: Double,
        in bounds: inout LayoutRect,
        output: inout [Tile]
    ) {
        let stripHeight = min(bounds.height, rowArea / bounds.width)
        guard stripHeight.isFinite, stripHeight > 0 else { return }

        var cursorX = bounds.x
        for (index, node) in row.enumerated() {
            let width = index == row.indices.last
                ? max(0, bounds.maxX - cursorX)
                : min(max(0, node.area / stripHeight), bounds.maxX - cursorX)

            appendTile(
                node,
                frame: LayoutRect(x: cursorX, y: bounds.y, width: width, height: stripHeight),
                to: &output
            )
            cursorX += width
        }

        bounds.y += stripHeight
        bounds.height = max(0, bounds.height - stripHeight)
    }

    private static func appendTile(
        _ node: Node,
        frame: LayoutRect,
        to output: inout [Tile]
    ) {
        output.append(
            Tile(
                sourceIndex: node.sourceIndex,
                ticker: node.ticker,
                weight: node.weight,
                fraction: node.fraction,
                frame: CGRect(
                    x: frame.x,
                    y: frame.y,
                    width: frame.width,
                    height: frame.height
                )
            )
        )
    }
}
