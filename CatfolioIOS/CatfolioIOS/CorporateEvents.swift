import Foundation
import Observation

/// One date in a holding's calendar: a results announcement, the day its
/// shares go ex-dividend, or the day a dividend is paid.
struct CorporateEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case earnings, exDividend, dividendPayment

        var isDividend: Bool { self != .earnings }
    }

    let ticker: String
    let kind: Kind
    /// yyyy-MM-dd.
    let date: String
    /// Projected from last year's pattern, or a date the company has not
    /// confirmed, rather than one it has announced.
    let isEstimate: Bool
    /// Per share, in the listing's quote currency.
    let amount: Double?
    let currency: String?

    var id: String { "\(ticker)|\(kind.rawValue)|\(date)" }
}

/// What one listing's calendar says, from Yahoo's calendar module and the
/// dividends it has paid.
struct CorporateEventSchedule: Codable, Sendable {
    let events: [CorporateEvent]
    let fetchedAt: Date

    /// Yahoo's calendar: the next earnings date, and the latest ex-dividend
    /// and payment dates it knows of.
    static func calendarEvents(_ data: Data, ticker: String) -> [CorporateEvent] {
        struct Response: Decodable {
            struct Summary: Decodable { let result: [Result]? }
            struct Result: Decodable { let calendarEvents: Calendar? }
            struct Calendar: Decodable {
                struct Earnings: Decodable {
                    let earningsDate: [Stamp]?
                    let isEarningsDateEstimate: Bool?
                }
                let earnings: Earnings?
                let exDividendDate: Stamp?
                let dividendDate: Stamp?
            }
            struct Stamp: Decodable { let raw: Double? }
            let quoteSummary: Summary
        }
        guard let calendar = (try? JSONDecoder().decode(Response.self, from: data))?
            .quoteSummary.result?.first?.calendarEvents else { return [] }
        var events: [CorporateEvent] = []
        // Yahoo gives a window of two dates while the day is unconfirmed;
        // the first is the one to plan around.
        if let stamp = calendar.earnings?.earningsDate?.compactMap(\.raw).min() {
            events.append(.init(ticker: ticker, kind: .earnings, date: day(stamp),
                isEstimate: calendar.earnings?.isEarningsDateEstimate ?? false, amount: nil, currency: nil))
        }
        if let stamp = calendar.exDividendDate?.raw {
            events.append(.init(ticker: ticker, kind: .exDividend, date: day(stamp),
                isEstimate: false, amount: nil, currency: nil))
        }
        if let stamp = calendar.dividendDate?.raw {
            events.append(.init(ticker: ticker, kind: .dividendPayment, date: day(stamp),
                isEstimate: false, amount: nil, currency: nil))
        }
        return events
    }

    /// Paid dividends as ex-dates, the next year's projected from them, and
    /// the calendar's own dates — an announced ex-date takes the place of a
    /// projected one near it and borrows its amount.
    static func merge(calendar: [CorporateEvent], payments: [DividendForecast.Payment], ticker: String,
                      today: Date = Date()) -> [CorporateEvent] {
        let todayText = day(today.timeIntervalSince1970)
        var events: [CorporateEvent] = payments.map {
            .init(ticker: ticker, kind: .exDividend, date: $0.exDate, isEstimate: false,
                  amount: $0.perShare, currency: $0.currency)
        }
        let yearAgo = shifted(todayText, years: -1)
        for payment in payments where payment.exDate > yearAgo {
            let next = shifted(payment.exDate, years: 1)
            guard next > todayText else { continue }
            events.append(.init(ticker: ticker, kind: .exDividend, date: next, isEstimate: true,
                                amount: payment.perShare, currency: payment.currency))
        }
        let latestAmount = payments.last.map { ($0.perShare, $0.currency) }
        for event in calendar {
            switch event.kind {
            case .earnings:
                events.append(event)
            case .exDividend:
                if events.contains(where: { $0.kind == .exDividend && !$0.isEstimate && $0.date == event.date }) { continue }
                let near = events.firstIndex { $0.kind == .exDividend && $0.isEstimate && daysBetween($0.date, event.date) <= 45 }
                let amount: Double? = near.flatMap { events[$0].amount } ?? (event.date > todayText ? latestAmount?.0 : nil)
                let currency: String? = near.flatMap { events[$0].currency } ?? latestAmount?.1
                if let near { events.remove(at: near) }
                events.append(.init(ticker: ticker, kind: .exDividend, date: event.date, isEstimate: false,
                                    amount: amount, currency: currency))
            case .dividendPayment:
                // Paid against the latest ex-date before it.
                let source = events.filter { $0.kind == .exDividend && $0.date <= event.date }.max { $0.date < $1.date }
                events.append(.init(ticker: ticker, kind: .dividendPayment, date: event.date, isEstimate: false,
                                    amount: source?.amount, currency: source?.currency))
            }
        }
        var seen = Set<String>()
        return events.filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
    }

    static func day(_ stamp: Double) -> String {
        DayDateCodec.string(from: Date(timeIntervalSince1970: stamp))
    }

    static func shifted(_ date: String, years: Int) -> String {
        guard let value = DayDateCodec.date(from: date),
              let moved = utcCalendar.date(byAdding: .year, value: years, to: value) else { return date }
        return DayDateCodec.string(from: moved)
    }

    static func daysBetween(_ a: String, _ b: String) -> Int {
        guard let x = DayDateCodec.date(from: a), let y = DayDateCodec.date(from: b) else { return .max }
        return abs(utcCalendar.dateComponents([.day], from: x, to: y).day ?? .max)
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// The portfolio's corporate calendar, one listing at a time, kept on disk
/// for half a day so the card and the calendar open on what was last seen.
@MainActor @Observable
final class CorporateEventsStore {
    static let shared = CorporateEventsStore()

    private(set) var schedules: [String: CorporateEventSchedule] = [:]
    private(set) var isLoading = false
    private var restored = false
    private var loadingKey: String?

    private static let maxAge: TimeInterval = 12 * 3_600
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("corporate-events-v1.json")
    }

    /// Every event for these tickers.
    func events(for tickers: Set<String>) -> [CorporateEvent] {
        tickers.flatMap { schedules[$0]?.events ?? [] }.sorted { ($0.date, $0.ticker) < ($1.date, $1.ticker) }
    }

    func load(tickers: [String]) async {
        restore()
        let wanted = Array(Set(tickers.map { $0.uppercased() })).sorted()
        let stale = wanted.filter { (schedules[$0].map { Date().timeIntervalSince($0.fetchedAt) > Self.maxAge }) ?? true }
        let key = stale.joined(separator: ",")
        guard !stale.isEmpty, loadingKey != key else { return }
        loadingKey = key
        isLoading = true
        defer { isLoading = false; loadingKey = nil }
        let crumb = await YahooCalendarClient.crumb()
        // A few at a time: Yahoo limits bursts, and a large portfolio is
        // dozens of listings.
        for chunk in stride(from: 0, to: stale.count, by: 4).map({ Array(stale[$0..<min(stale.count, $0 + 4)]) }) {
            let results = await withTaskGroup(of: (String, CorporateEventSchedule?).self) { group in
                for ticker in chunk {
                    group.addTask { (ticker, await YahooCalendarClient.schedule(ticker: ticker, crumb: crumb)) }
                }
                var collected: [(String, CorporateEventSchedule?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            guard !Task.isCancelled else { return }
            for (ticker, schedule) in results { if let schedule { schedules[ticker] = schedule } }
        }
        save()
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([String: CorporateEventSchedule].self, from: data) {
            schedules = stored
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

enum YahooCalendarClient {
    /// Yahoo's calendar module wants a session crumb; without one the
    /// calendar is skipped and dividends still come from their history.
    static func crumb() async -> String? {
        var bootstrap = URLRequest(url: URL(string: "https://fc.yahoo.com")!, timeoutInterval: 10)
        bootstrap.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        _ = try? await URLSession.shared.data(for: bootstrap)
        var request = URLRequest(url: URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let crumb = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !crumb.isEmpty, crumb.count < 100,
              !crumb.contains(where: { $0.isWhitespace || $0 == "<" || $0 == "{" }) else { return nil }
        return crumb
    }

    /// Nil when nothing could be read, so the previous schedule is kept.
    static func schedule(ticker: String, crumb: String?) async -> CorporateEventSchedule? {
        async let payments = try? LocalMarketDataClient().dividendPayments(symbol: ticker)
        var calendar: [CorporateEvent]?
        if let crumb, let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            var components = URLComponents(string: "https://query2.finance.yahoo.com/v10/finance/quoteSummary/\(encoded)")!
            components.queryItems = [URLQueryItem(name: "modules", value: "calendarEvents"),
                                     URLQueryItem(name: "crumb", value: crumb)]
            var request = URLRequest(url: components.url!, timeoutInterval: 15)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                calendar = CorporateEventSchedule.calendarEvents(data, ticker: ticker)
            }
        }
        let history = await payments
        guard calendar != nil || history != nil else { return nil }
        // Past results days, from the earnings history already read for the
        // security page; nothing is fetched for them here.
        let reported = (await EarningsHistoryClient.shared.cached(symbol: ticker))?.observations.map {
            CorporateEvent(ticker: ticker, kind: .earnings, date: $0.date, isEstimate: false, amount: nil, currency: nil)
        } ?? []
        return CorporateEventSchedule(
            events: CorporateEventSchedule.merge(calendar: reported + (calendar ?? []), payments: history ?? [], ticker: ticker),
            fetchedAt: Date())
    }
}
