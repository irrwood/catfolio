import Foundation

enum TodaySectorSortOrder: String, CaseIterable {
    case gains, losses

    /// Compare money moved, not the number of gaining or losing sectors.
    /// Balanced and empty days keep the stable gains-first order.
    static func automatic(for amounts: [Double]) -> Self {
        amounts.reduce(0, +) < 0 ? .losses : .gains
    }

    func sorted<Row>(_ rows: [Row], amount: KeyPath<Row, Double>, id: KeyPath<Row, String>) -> [Row] {
        rows.sorted { lhs, rhs in
            let left = lhs[keyPath: amount], right = rhs[keyPath: amount]
            if left == right { return lhs[keyPath: id] < rhs[keyPath: id] }
            return self == .gains ? left > right : left < right
        }
    }
}
