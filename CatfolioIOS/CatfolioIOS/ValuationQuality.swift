import Foundation

/// Annual, unadjusted accounting ROIC. Values retain their filing provenance;
/// this is deliberately separate from JEV's existing TTM valuation calculation.
struct ValuationQuality: Codable, Equatable, Sendable {
    let periodStart: String
    let periodEnd: String
    let filed: String
    let accession: String?
    let dilutedEPS: Double?
    let priorDilutedEPS: Double?
    let operatingIncome: Double?
    let pretaxIncome: Double?
    let incomeTax: Double?
    let openingCapital: Double?
    let closingCapital: Double?
    var cik: Int? = nil

    var filingURL: URL? {
        guard let cik, cik > 0, let accession else { return nil }
        return URL(string: "https://www.sec.gov/Archives/edgar/data/\(cik)/\(accession.replacingOccurrences(of: "-", with: ""))/\(accession)-index.html")
    }

    var epsGrowthPercent: Double? {
        guard let current = dilutedEPS, let prior = priorDilutedEPS,
              current.isFinite, prior.isFinite, prior > 0 else { return nil }
        let result = (current / prior - 1) * 100
        return result.isFinite ? result : nil
    }
    var effectiveTaxRate: Double? {
        guard let pretaxIncome, pretaxIncome > 0, let incomeTax else { return nil }
        let rate = incomeTax / pretaxIncome
        return rate.isFinite && (0...1).contains(rate) ? rate : nil
    }
    var averageCapital: Double? {
        guard let openingCapital, let closingCapital,
              openingCapital > 0, closingCapital > 0 else { return nil }
        let average = (openingCapital + closingCapital) / 2
        return average.isFinite && average > 0 ? average : nil
    }
    var nopat: Double? {
        guard let operatingIncome, let effectiveTaxRate else { return nil }
        let result = operatingIncome * (1 - effectiveTaxRate)
        return result.isFinite ? result : nil
    }
    var roicPercent: Double? {
        guard let nopat, let averageCapital else { return nil }
        let result = nopat / averageCapital * 100
        return result.isFinite ? result : nil
    }
    var epsUnavailableReason: String? {
        if dilutedEPS == nil || priorDilutedEPS == nil { return L10n.text("缺少同一申报中的两年稀释 EPS") }
        if (priorDilutedEPS ?? 0) <= 0 { return L10n.text("上年 EPS 不为正，增长率不适用") }
        return epsGrowthPercent == nil ? L10n.text("EPS 数据无法计算") : nil
    }
    var roicUnavailableReason: String? {
        if operatingIncome == nil { return L10n.text("缺少营业利润") }
        if pretaxIncome == nil || incomeTax == nil { return L10n.text("缺少税前利润或所得税费用") }
        if effectiveTaxRate == nil { return L10n.text("税前利润或有效税率异常") }
        if openingCapital == nil || closingCapital == nil { return L10n.text("缺少完整债务、权益或现金数据") }
        if averageCapital == nil { return L10n.text("期初或期末投入资本不为正") }
        return roicPercent == nil ? L10n.text("ROIC 数据无法计算") : nil
    }
}

enum SECQualityCalculator {
    typealias Fact = CompanyFinancialsClient.SECFactValue
    typealias Namespace = [String: CompanyFinancialsClient.SECFact]

    /// Both EPS years come from the same annual filing so comparative EPS is
    /// restated on the same split basis. Quarter/YTD figures are never summed.
    static func calculate(_ facts: [String: Namespace], cik: Int? = nil) -> ValuationQuality? {
        guard let ns = facts["us-gaap"] else { return nil }
        let anchors = values(ns, ["EarningsPerShareDiluted"], unit: "USD/shares")
            + values(ns, ["OperatingIncomeLoss"], unit: "USD")
        guard let annual = anchors.filter({ fact in
            guard ["10-K", "10-K/A"].contains(fact.form ?? ""), let start = fact.start else { return false }
            return (330...380).contains(days(start, fact.end))
        }).max(by: { ($0.end, $0.filed ?? "") < ($1.end, $1.filed ?? "") }),
              let start = annual.start, let filed = annual.filed else { return nil }

        func sameFiling(_ fact: Fact) -> Bool {
            if let accession = annual.accession { return fact.accession == accession }
            return fact.filed == filed && fact.form == annual.form
        }
        func number(_ tags: [String], unit: String = "USD", start: String? = nil, end: String) -> Double? {
            for tag in tags {
                let rows = values(ns, [tag], unit: unit).filter {
                    sameFiling($0) && $0.end == end && $0.start == start && $0.value.isFinite
                }
                // Ambiguous contexts must not become a made-up consolidated value.
                let unique = Set(rows.map(\.value))
                if unique.count == 1 { return unique.first }
            }
            return nil
        }
        let previousEPS = values(ns, ["EarningsPerShareDiluted"], unit: "USD/shares")
            .filter { fact in
                guard sameFiling(fact), let priorStart = fact.start else { return false }
                return (330...380).contains(days(priorStart, fact.end))
                    && (350...380).contains(days(fact.end, annual.end))
            }.max(by: { $0.end < $1.end })
        let priorEPS = previousEPS.flatMap { number(["EarningsPerShareDiluted"], unit: "USD/shares", start: $0.start, end: $0.end) }
        let balanceDates = values(ns, ["StockholdersEquity", "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"], unit: "USD")
            .filter { sameFiling($0) && $0.start == nil && (1...8).contains(days($0.end, start)) }
        let openingDate = balanceDates.map(\.end).max()

        func capital(at end: String) -> Double? {
            guard let equity = number(["StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest", "StockholdersEquity"], end: end),
                  let cash = number(["CashAndCashEquivalentsAtCarryingValue"], end: end), cash >= 0 else { return nil }
            let totalDebt: Double?
            if let total = number(["LongTermDebtAndShortTermBorrowings"], end: end) {
                totalDebt = total
            } else if let current = number(["DebtCurrent"], end: end),
                      let noncurrent = number(["LongTermDebtNoncurrent"], end: end) {
                totalDebt = current + noncurrent
            } else {
                // Never take LongTermDebtCurrent alone as total debt, and never
                // infer an absent short-term borrowing amount to be zero.
                let short = number(["ShortTermBorrowings"], end: end)
                    ?? number(["CommercialPaper"], end: end).map {
                        $0 + (number(["OtherShortTermBorrowings"], end: end) ?? 0)
                    }
                let long: Double?
                if let current = number(["LongTermDebtCurrent"], end: end),
                   let noncurrent = number(["LongTermDebtNoncurrent"], end: end) {
                    long = current + noncurrent
                } else {
                    long = number(["LongTermDebt"], end: end)
                }
                if let short, let long, short >= 0, long >= 0 { totalDebt = short + long }
                else { totalDebt = nil }
            }
            guard let totalDebt, totalDebt >= 0 else { return nil }
            let result = equity + totalDebt - cash
            return result.isFinite ? result : nil
        }
        return ValuationQuality(
            periodStart: start, periodEnd: annual.end, filed: filed, accession: annual.accession,
            dilutedEPS: number(["EarningsPerShareDiluted"], unit: "USD/shares", start: start, end: annual.end),
            priorDilutedEPS: priorEPS,
            operatingIncome: number(["OperatingIncomeLoss"], start: start, end: annual.end),
            pretaxIncome: number([
                "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest",
                "IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments",
            ], start: start, end: annual.end),
            incomeTax: number(["IncomeTaxExpenseBenefit"], start: start, end: annual.end),
            openingCapital: openingDate.flatMap { capital(at: $0) }, closingCapital: capital(at: annual.end), cik: cik
        )
    }
    private static func values(_ ns: Namespace, _ tags: [String], unit: String) -> [Fact] {
        tags.flatMap { ns[$0]?.units[unit] ?? [] }
    }
    private static func days(_ start: String, _ end: String) -> Int {
        guard let a = DayDateCodec.date(from: start), let b = DayDateCodec.date(from: end) else { return Int.min }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }
}
