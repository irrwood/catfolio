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

/// The existing metadata badge also identifies a current extended session.
/// Its owner supplies the same timeline date used to choose the main quote.
struct MarketClosedBadge: View {
    let ticker: String
    var extendedHoursQuote: ExtendedHoursQuote? = nil
    var date: Date = .now
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var badgeHeight: CGFloat = 18
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 10
    // The exported sun occupies 17 of its 24 points vertically. A 16-point
    // canvas makes the visible artwork match the adjacent 12-point caption.
    @ScaledMetric(relativeTo: .caption) private var postMarketIconSize: CGFloat = 16
    private let purple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var session: USMarketSession {
        if let extendedHoursQuote, extendedHoursQuote.isCurrentSession(at: date) {
            return extendedHoursQuote.session
        }
        return MarketHours.isOpen(ticker: ticker, at: date) ? .regular : .closed
    }

    private var title: String {
        switch session {
        case .preMarket: L10n.text("盘前")
        case .postMarket: L10n.text("盘后")
        default: L10n.text("休市")
        }
    }

    var body: some View {
        if session != .regular {
            HStack(spacing: 2) {
                if session.isExtended {
                    Group {
                        if session == .postMarket {
                            RotatingSunriseIcon(size: postMarketIconSize)
                        } else {
                            Image(systemName: "sunrise.fill")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: iconSize, height: iconSize)
                        }
                    }
                    .researchLayoutFrame("extended-hours.icon")
                } else {
                    Image(systemName: "moon.fill").font(.system(size: 9, weight: .semibold))
                }
                Text(title).appText(.caption, weight: .medium)
            }
            .foregroundStyle(purple)
            .padding(.horizontal, 4)
            .frame(height: badgeHeight)
            .background(purple.opacity(colorScheme == .dark ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.isExtended ? title : L10n.text("非交易时段"))
        }
    }
}
