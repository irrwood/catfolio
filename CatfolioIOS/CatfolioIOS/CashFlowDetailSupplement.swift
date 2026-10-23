import Foundation

extension CompanyFinancialsClient {
    /// Supplements classifications only after the providers agree on all
    /// three cash-flow totals. The primary statement remains authoritative.
    static func supplementingCashFlowDetails(
        to primary: [CashFlowStatementPeriod], from supplement: [CashFlowStatementPeriod]
    ) -> (periods: [CashFlowStatementPeriod], didSupplement: Bool) {
        var didSupplement = false
        let cashReconciliationItems: Set<CashFlowLineItem> = [
            .cashAtBeginningOfPeriod, .cashAtEndOfPeriod, .changeInCash, .effectOfExchangeRates,
        ]
        func agrees(_ first: Double?, _ second: Double?) -> Bool {
            guard let first, first.isFinite, let second, second.isFinite else { return false }
            let tolerance = max(1, max(abs(first), abs(second)) * 0.000_001)
            return abs(first - second) <= tolerance
        }
        let periods = primary.map { original in
            guard let candidate = supplement.first(where: {
                $0.periodEnd == original.periodEnd && $0.kind == original.kind
                    && $0.currency == original.currency
                    && agrees(original.operatingCashFlow, $0.operatingCashFlow)
                    && agrees(original.investingCashFlow, $0.investingCashFlow)
                    && agrees(original.financingCashFlow, $0.financingCashFlow)
            }), let incoming = candidate.details else { return original }

            var details = original.details ?? CashFlowDetails()
            let matchingCashScope = details.cashIncludesRestrictedCash != nil
                && details.cashIncludesRestrictedCash == incoming.cashIncludesRestrictedCash
            var changed = false
            for item in CashFlowLineItem.allCases {
                if cashReconciliationItems.contains(item), !matchingCashScope { continue }
                guard let value = incoming.value(item) else { continue }
                let existing = details.value(item)
                let replacesPartial = details.isPartial(item) && !incoming.isPartial(item)
                guard existing == nil || replacesPartial else { continue }

                details.amounts[item] = value
                if incoming.isPartial(item) {
                    if details.partialItems == nil { details.partialItems = [] }
                    details.partialItems?.insert(item)
                } else {
                    details.partialItems?.remove(item)
                }
                if let concepts = incoming.sourceConcepts?[item] {
                    if details.sourceConcepts == nil { details.sourceConcepts = [:] }
                    details.sourceConcepts?[item] = concepts
                } else {
                    details.sourceConcepts?.removeValue(forKey: item)
                }
                changed = true
            }
            if details.sourceFreeCashFlow == nil, let source = incoming.sourceFreeCashFlow, source.isFinite {
                details.sourceFreeCashFlow = source
                changed = true
            }
            guard changed else { return original }
            var result = original
            result.details = details
            didSupplement = true
            return result
        }
        return (periods, didSupplement)
    }
}
