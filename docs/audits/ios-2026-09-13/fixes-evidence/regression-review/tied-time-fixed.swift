import Foundation
struct Record {
 let date: String; let action: String; let executedAt: String?; let id: String
    static func orderedForLotMatching(_ rows: [Self]) -> [Self] {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle()
        return rows.map { row -> (row: Self, time: TimeInterval, isBuy: Bool) in
            let isBuy = ["BUY", "BUY_BACK"].contains(row.action.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            let time = row.executedAt.flatMap { text in
                (try? fractional.parse(text)) ?? (try? whole.parse(text))
            }?.timeIntervalSince1970
            return (row, time ?? (isBuy ? -.infinity : .infinity), isBuy)
        }.sorted {
            if $0.row.date != $1.row.date { return $0.row.date < $1.row.date }
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.isBuy != $1.isBuy { return $0.isBuy }
            return $0.row.id < $1.row.id
        }.map(\.row)
    }

}
let rows = [Record(date: "2024-01-02", action: "BUY", executedAt: "2024-01-02T00:00:00Z", id: "z-buy"),Record(date: "2024-01-02", action: "SELL", executedAt: "2024-01-02T00:00:00Z", id: "a-sell")]
print(Record.orderedForLotMatching(rows).map(\.action))
