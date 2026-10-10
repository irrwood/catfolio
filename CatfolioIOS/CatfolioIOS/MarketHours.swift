import SwiftUI
import UIKit

/// Whether a listing's exchange is in its regular session now, from the
/// ticker's market suffix. Weekends count as closed; exchange holidays are
/// not known here and read as open.
enum MarketHours {
    private struct Session {
        let timeZone: String
        let open: Int   // minutes after midnight, local
        let close: Int
    }

    private static func session(for ticker: String) -> Session {
        let symbol = ticker.uppercased()
        func local(_ zone: String, _ open: (Int, Int), _ close: (Int, Int)) -> Session {
            Session(timeZone: zone, open: open.0 * 60 + open.1, close: close.0 * 60 + close.1)
        }
        if symbol.hasSuffix(".L") { return local("Europe/London", (8, 0), (16, 30)) }
        if symbol.hasSuffix(".DE") || symbol.hasSuffix(".F") { return local("Europe/Berlin", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".PA") || symbol.hasSuffix(".AS") || symbol.hasSuffix(".BR") || symbol.hasSuffix(".LS") {
            return local("Europe/Paris", (9, 0), (17, 30))
        }
        if symbol.hasSuffix(".MI") { return local("Europe/Rome", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".MC") { return local("Europe/Madrid", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".SW") { return local("Europe/Zurich", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".CO") { return local("Europe/Copenhagen", (9, 0), (17, 0)) }
        if symbol.hasSuffix(".ST") { return local("Europe/Stockholm", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".HK") { return local("Asia/Hong_Kong", (9, 30), (16, 0)) }
        if symbol.hasSuffix(".T") { return local("Asia/Tokyo", (9, 0), (15, 30)) }
        if symbol.hasSuffix(".TO") { return local("America/Toronto", (9, 30), (16, 0)) }
        return local("America/New_York", (9, 30), (16, 0))
    }

    static func isOpen(ticker: String, at date: Date = Date()) -> Bool {
        let session = session(for: ticker)
        guard let zone = TimeZone(identifier: session.timeZone) else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, (2...6).contains(weekday) else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= session.open && minute < session.close
    }
}

/// Outside the listing's trading session: a moon, in the class badge's shape,
/// purple on a pale purple ground. Checks again every minute.
struct MarketClosedBadge: View {
    let ticker: String
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var badgeHeight: CGFloat = 18
    private let purple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if !MarketHours.isOpen(ticker: ticker, at: context.date) {
                HStack(spacing: 2) {
                    Image(systemName: "moon.fill").font(.system(size: 9, weight: .semibold))
                    Text(L10n.text("休市")).appText(.caption, weight: .medium)
                }
                .foregroundStyle(purple)
                .padding(.horizontal, 4)
                .frame(height: badgeHeight)
                .background(purple.opacity(colorScheme == .dark ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 3))
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("非交易时段"))
            }
        }
    }
}
