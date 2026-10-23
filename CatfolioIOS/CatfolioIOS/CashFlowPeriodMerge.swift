import Foundation

extension CompanyFinancialsClient {
    /// Supplement a lagging feed without replacing a filing's existing periods
    /// with a provider's different cash-flow definition.
    static func addingNewerCashFlowPeriods(
        to primary: [CashFlowStatementPeriod],
        from supplement: [CashFlowStatementPeriod]
    ) -> [CashFlowStatementPeriod] {
        let currencies = Set(primary.map(\.currency))
        var result = primary
        for kind in [FinancialPeriodKind.annual, .quarterly] {
            let latest = primary.filter { $0.kind == kind }.map(\.periodEnd).max()
            let candidates = supplement.filter {
                $0.kind == kind && $0.operatingCashFlow.isFinite
                    && (currencies.isEmpty || currencies.contains($0.currency))
                    && (latest == nil || $0.periodEnd > latest!)
            }.sorted { ($0.periodEnd, $0.filedDate ?? "") > ($1.periodEnd, $1.filedDate ?? "") }
            for candidate in candidates where !result.contains(where: {
                $0.kind == kind && $0.periodEnd == candidate.periodEnd
            }) {
                result.append(candidate)
            }
        }
        return result.sorted {
            if $0.periodEnd != $1.periodEnd { return $0.periodEnd > $1.periodEnd }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }
}
