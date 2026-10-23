import Foundation

extension CompanyFinancialsClient {
    static func fmpCashFlowDetails(_ row: FMPCashRow) -> CashFlowDetails {
        var details = CashFlowDetails()
        func put(_ item: CashFlowLineItem, _ value: Double?) {
            if let value, value.isFinite { details.amounts[item] = value }
        }
        func payment(_ value: Double?) -> Double? { value.map { -abs($0) } }
        put(.netIncome, row.netIncome)
        put(.depreciationAndAmortization, row.depreciationAndAmortization)
        put(.deferredIncomeTaxes, row.deferredIncomeTax)
        put(.stockBasedCompensation, row.stockBasedCompensation)
        put(.changeInWorkingCapital, row.changeInWorkingCapital)
        put(.otherNonCashItems, row.otherNonCashItems)
        put(.acquisitions, row.acquisitionsNet)
        put(.investmentPurchases, payment(row.purchasesOfInvestments))
        put(.investmentSalesAndMaturities, row.salesMaturitiesOfInvestments)
        put(.otherInvestingActivities, row.otherInvestingActivities)
        put(.debtRepaid, payment(row.debtRepayment))
        // Net debt issuance is not gross proceeds. Keep the latter absent
        // unless a provider actually supplies it.
        put(.dividendsPaid, payment(row.dividendsPaid ?? row.netDividendsPaid ?? row.commonDividendsPaid))
        put(.commonStockRepurchased, payment(row.commonStockRepurchased))
        put(.commonStockIssued, row.commonStockIssued)
        put(.financeLeasePrincipalPayments, payment(row.financeLeasePrincipalPayments))
        put(.otherFinancingActivities, row.otherFinancingActivities)
        put(.effectOfExchangeRates, row.effectOfForexChangesOnCash)
        put(.changeInCash, row.netChangeInCash)
        put(.cashAtBeginningOfPeriod, row.cashAtBeginningOfPeriod)
        put(.cashAtEndOfPeriod, row.cashAtEndOfPeriod)
        if let freeCashFlow = row.freeCashFlow, freeCashFlow.isFinite {
            details.sourceFreeCashFlow = freeCashFlow
        }
        return details
    }

    static func nasdaqCashFlowDetails(column: String, rows: [String: [String: String]]) -> CashFlowDetails {
        var details = CashFlowDetails()
        func amount(_ labels: [String]) -> Double? { nasdaqValue(labels, column: column, rows: rows) }
        func put(_ item: CashFlowLineItem, _ labels: [String]) {
            if let value = amount(labels), value.isFinite { details.amounts[item] = value }
        }
        func payment(_ item: CashFlowLineItem, _ labels: [String]) {
            if let value = amount(labels), value.isFinite { details.amounts[item] = -abs(value) }
        }
        put(.netIncome, ["Net Income", "Net Income (Loss)"])
        put(.depreciationAndAmortization, ["Depreciation and Amortization", "Depreciation/Depletion", "Depreciation"])
        put(.deferredIncomeTaxes, ["Deferred Income Taxes", "Deferred Taxes"])
        put(.stockBasedCompensation, ["Stock Based Compensation", "Stock-Based Compensation"])
        put(.changeInWorkingCapital, ["Change in Working Capital", "Changes in Working Capital"])
        put(.otherNonCashItems, ["Other Non-Cash Items", "Other Noncash Items"])
        payment(.acquisitions, ["Acquisitions, Net", "Acquisitions"])
        payment(.investmentPurchases, ["Purchases of Investments", "Investment Purchases"])
        put(.investmentSalesAndMaturities, ["Sales/Maturities of Investments", "Sales of Investments", "Sale and Maturity of Investments"])
        put(.otherInvestingActivities, ["Other Investing Activities", "Other Investing Cash Flows"])
        put(.debtIssued, ["Debt Issued", "Issuance of Debt"])
        payment(.debtRepaid, ["Debt Repayment", "Repayment of Debt"])
        payment(.dividendsPaid, ["Cash Dividends Paid", "Dividends Paid"])
        payment(.commonStockRepurchased, ["Common Stock Repurchased", "Repurchase of Common Stock"])
        put(.commonStockIssued, ["Common Stock Issued", "Issuance of Common Stock"])
        payment(.financeLeasePrincipalPayments, ["Finance Lease Principal Payments"])
        put(.otherFinancingActivities, ["Other Financing Activities", "Other Financing Cash Flows"])
        put(.effectOfExchangeRates, ["Effect of Exchange Rate Changes", "Effect of Exchange Rate Changes on Cash", "Effect of Exchange Rates"])
        put(.changeInCash, ["Increase/Decrease in Cash", "Net Change in Cash", "Change in Cash and Cash Equivalents"])
        put(.cashAtBeginningOfPeriod, ["Cash at Beginning of Period", "Cash and Cash Equivalents - Beginning of Period"])
        put(.cashAtEndOfPeriod, ["Cash at End of Period", "Cash and Cash Equivalents - End of Period"])
        if let source = amount(["Free Cash Flow"]), source.isFinite { details.sourceFreeCashFlow = source }
        return details
    }

    /// Standard taxonomy disclosures only. Missing company-specific facts stay
    /// unavailable; absence of a tag is not evidence of a zero cash flow.
    static func secCashFlowDetails(
        namespace: [String: SECFact], anchor: AnchorPeriod, asOf filed: String
    ) -> CashFlowDetails {
        var details = CashFlowDetails(sourceConcepts: [:])
        var resolvedConcepts = Set<String>()
        func amount(_ concepts: [String]) -> Double? {
            guard let match = cashDetailValue(concepts, namespace: namespace, anchor: anchor, asOf: filed) else { return nil }
            resolvedConcepts.insert(match.concept)
            return match.value
        }
        func hasAmount(_ concepts: [String]) -> Bool {
            cashDetailValue(concepts, namespace: namespace, anchor: anchor, asOf: filed) != nil
        }
        func put(_ item: CashFlowLineItem, _ value: Double?) {
            if let value, value.isFinite {
                details.amounts[item] = value
                details.sourceConcepts?[item] = resolvedConcepts
            }
            resolvedConcepts.removeAll()
        }
        func partial(_ item: CashFlowLineItem) {
            if details.value(item) != nil {
                if details.partialItems == nil { details.partialItems = [] }
                details.partialItems?.insert(item)
            }
        }
        func sum(_ values: [Double?]) -> Double? {
            let known = values.compactMap { $0 }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        func outflow(_ concepts: [String]) -> Double? { amount(concepts).map { -$0 } }
        put(.netIncome, amount(["NetIncomeLoss", "ProfitLoss"]))
        put(.depreciationAndAmortization, amount([
            "DepreciationDepletionAndAmortization", "DepreciationAmortizationAndAccretionNet",
            "DepreciationAndAmortisationExpense",
        ]) ?? sum([
            amount(["DepreciationDepletionAndAmortizationPropertyPlantAndEquipment", "Depreciation"]),
            amount(["AmortizationOfIntangibleAssets", "AmortizationOfIntangibleAssetsExcludingGoodwill"]),
        ]))
        if !hasAmount(["DepreciationDepletionAndAmortization", "DepreciationAmortizationAndAccretionNet",
                       "DepreciationAndAmortisationExpense"]) {
            partial(.depreciationAndAmortization)
        }
        put(.deferredIncomeTaxes, amount(["DeferredIncomeTaxExpenseBenefit", "DeferredIncomeTaxesAndTaxCredits"]))
        put(.stockBasedCompensation, amount(["ShareBasedCompensation", "SharebasedPaymentExpense"]))
        // These concepts are income/expense and asset changes, rather than
        // signed cash receipts. An income or an increase in assets is removed
        // in the indirect reconciliation.
        put(.otherNonCashItems, amount(["OtherNoncashIncomeExpense", "OtherNoncashIncomeExpenseNet"]).map { -$0 })
        let workingCapital = amount(["IncreaseDecreaseInOperatingCapital"]).map { -$0 }
            ?? secWorkingCapitalChange(amount: amount)
        put(.changeInWorkingCapital, workingCapital)
        if !hasAmount(["IncreaseDecreaseInOperatingCapital"]) { partial(.changeInWorkingCapital) }
        partial(.otherNonCashItems)

        put(.acquisitions, outflow([
            "PaymentsToAcquireBusinessesNetOfCashAcquired", "PaymentsToAcquireBusinessesNetOfCashAcquiredAndDivestitures",
            "PaymentsToAcquireBusinessesGross",
        ]))
        let investmentPurchases = outflow(["PaymentsToAcquireInvestments", "PaymentsToAcquireInvestmentSecurities"])
            ?? sum([
                outflow(["PaymentsToAcquireAvailableForSaleSecurities", "PaymentsToAcquireAvailableForSaleSecuritiesDebt"]),
                outflow(["PaymentsToAcquireHeldToMaturitySecurities"]),
                outflow(["PaymentsToAcquireEquityMethodInvestments"]),
                outflow(["PaymentsToAcquireEquitySecuritiesFvNi", "PaymentsToAcquireOtherInvestments"]),
            ])
        put(.investmentPurchases, investmentPurchases)
        if !hasAmount(["PaymentsToAcquireInvestments", "PaymentsToAcquireInvestmentSecurities"]) {
            partial(.investmentPurchases)
        }
        let investmentSales = amount(["ProceedsFromSaleMaturityAndCollectionsOfInvestments"])
            ?? sum([
                amount(["ProceedsFromSaleAndMaturityOfAvailableForSaleSecurities"])
                    ?? sum([
                        amount(["ProceedsFromSaleOfAvailableForSaleSecurities", "ProceedsFromSaleOfAvailableForSaleSecuritiesDebt"]),
                        amount(["ProceedsFromMaturitiesPrepaymentsAndCallsOfAvailableForSaleSecurities", "ProceedsFromMaturitiesPrepaymentsAndCallsOfAvailableForSaleSecuritiesDebt"]),
                    ]),
                amount(["ProceedsFromSaleAndMaturityOfHeldToMaturitySecurities"]),
                amount(["ProceedsFromSaleOfEquitySecuritiesFvNi", "ProceedsFromSaleOfOtherInvestments"]),
            ])
        put(.investmentSalesAndMaturities, investmentSales)
        if !hasAmount(["ProceedsFromSaleMaturityAndCollectionsOfInvestments"]) {
            partial(.investmentSalesAndMaturities)
        }
        put(.otherInvestingActivities, amount(["ProceedsFromPaymentsForOtherInvestingActivities"])
            ?? amount(["PaymentsForProceedsFromOtherInvestingActivities"]).map { -$0 })

        put(.debtIssued, amount(["ProceedsFromIssuanceOfDebt", "ProceedsFromIssuanceOfDebtAndCapitalSecurities"])
            ?? sum([
                amount(["ProceedsFromIssuanceOfLongTermDebt", "ProceedsFromIssuanceOfSeniorLongTermDebt"]),
                amount(["ProceedsFromShortTermDebt", "ProceedsFromIssuanceOfShortTermDebt"]),
            ]))
        if !hasAmount(["ProceedsFromIssuanceOfDebt", "ProceedsFromIssuanceOfDebtAndCapitalSecurities"]) {
            partial(.debtIssued)
        }
        put(.debtRepaid, outflow(["RepaymentsOfDebt"])
            ?? sum([
                outflow(["RepaymentsOfLongTermDebt", "RepaymentsOfLongTermDebtAndCapitalSecurities"]),
                outflow(["RepaymentsOfShortTermDebt"]),
            ]))
        if !hasAmount(["RepaymentsOfDebt"]) { partial(.debtRepaid) }
        put(.dividendsPaid, outflow(["PaymentsOfDividends", "PaymentsOfDividendsCommonStock", "PaymentsOfOrdinaryDividends"]))
        if !hasAmount(["PaymentsOfDividends"]) { partial(.dividendsPaid) }
        put(.commonStockRepurchased, outflow(["PaymentsForRepurchaseOfCommonStock"]))
        // Issuance totals can include option exercises. Never add those
        // proceeds to an already disclosed stock issuance total.
        put(.commonStockIssued, amount(["ProceedsFromIssuanceOfCommonStock"])
            ?? amount(["ProceedsFromStockOptionsExercised"]))
        if !hasAmount(["ProceedsFromIssuanceOfCommonStock"]) {
            partial(.commonStockIssued)
        }
        put(.financeLeasePrincipalPayments, outflow(["FinanceLeasePrincipalPayments", "RepaymentsOfCapitalLeaseObligations"]))
        put(.otherFinancingActivities, amount(["ProceedsFromPaymentsForOtherFinancingActivities"])
            ?? amount(["PaymentsForProceedsFromOtherFinancingActivities"]).map { -$0 })

        partial(.otherInvestingActivities)
        partial(.otherFinancingActivities)

        // The cash-flow reconciliation may include restricted cash while the
        // balance sheet's headline cash figure excludes it. Select one scope
        // for both balances, the change and the exchange-rate effect.
        let scopes: [(restricted: Bool, balance: [String], change: [String], fx: [String])] = [
            (true, ["CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents"],
             ["CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect"],
             ["EffectOfExchangeRateOnCashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents"]),
            (false, ["CashAndCashEquivalentsAtCarryingValue", "CashAndCashEquivalents"],
             ["CashAndCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect", "IncreaseDecreaseInCashAndCashEquivalents"],
             ["EffectOfExchangeRateOnCashAndCashEquivalents", "EffectOfExchangeRateChangesOnCashAndCashEquivalents"]),
        ]
        let scope = scopes.first { hasAmount($0.change) }
            ?? scopes.first { hasAmount($0.fx) }
            ?? scopes.first {
                cashDetailInstant($0.balance, namespace: namespace, unit: anchor.unit,
                    end: anchor.entry.end, asOf: filed) != nil
            }
        if let scope {
            details.cashIncludesRestrictedCash = scope.restricted
            put(.changeInCash, amount(scope.change))
            put(.effectOfExchangeRates, amount(scope.fx))
            put(.cashAtEndOfPeriod, cashDetailInstant(scope.balance, namespace: namespace,
                unit: anchor.unit, end: anchor.entry.end, asOf: filed))
            if let start = anchor.entry.start, let openingDate = cashDateBefore(start) {
                put(.cashAtBeginningOfPeriod, cashDetailInstant(scope.balance, namespace: namespace,
                    unit: anchor.unit, end: openingDate, asOf: filed))
            }
        }
        return details
    }

    /// Uses mutually exclusive aggregate/child groups. Operating assets are
    /// inverted; operating liabilities keep their disclosed direction.
    private static func secWorkingCapitalChange(amount: ([String]) -> Double?) -> Double? {
        func asset(_ concepts: [String]) -> Double? { amount(concepts).map { -$0 } }
        func total(_ values: [Double?]) -> Double? {
            let known = values.compactMap { $0 }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        let receivables = asset(["IncreaseDecreaseInReceivables", "IncreaseDecreaseInAccountsReceivable"])
        let inventory = asset(["IncreaseDecreaseInInventories", "IncreaseDecreaseInInventoriesNet"])
        let prepaidAndOther = asset(["IncreaseDecreaseInPrepaidDeferredExpenseAndOtherAssets"])
            ?? total([
                asset(["IncreaseDecreaseInPrepaidDeferredExpense", "IncreaseDecreaseInPrepaidExpenses"]),
                asset(["IncreaseDecreaseInOtherOperatingAssets", "IncreaseDecreaseInOtherCurrentAssets"]),
            ])
        let payableAndAccrued = amount(["IncreaseDecreaseInAccountsPayableAndAccruedLiabilities"])
            ?? total([
                amount(["IncreaseDecreaseInAccountsPayable", "IncreaseDecreaseInAccountsPayableTrade"]),
                amount(["IncreaseDecreaseInAccruedLiabilities", "IncreaseDecreaseInAccruedLiabilitiesCurrent"]),
            ])
        return total([
            receivables, inventory, prepaidAndOther, payableAndAccrued,
            amount(["IncreaseDecreaseInOtherOperatingLiabilities"])
                ?? amount(["IncreaseDecreaseInOtherNoncurrentLiabilities"]),
            amount(["IncreaseDecreaseInIncomeTaxesPayable", "IncreaseDecreaseInIncomeTaxes"]),
            amount(["IncreaseDecreaseInDeferredRevenue", "IncreaseDecreaseInContractWithCustomerLiability"]),
        ])
    }

    /// Duration facts are differenced; cash balances are point-in-time facts.
    static func quarterCashFlowDetails(current: CashFlowDetails, previous: CashFlowDetails) -> CashFlowDetails {
        var result = CashFlowDetails(cashIncludesRestrictedCash: current.cashIncludesRestrictedCash,
            partialItems: Set((current.partialItems ?? []).union(previous.partialItems ?? [])), sourceConcepts: [:])
        let matchingCashScope = current.cashIncludesRestrictedCash != nil
            && current.cashIncludesRestrictedCash == previous.cashIncludesRestrictedCash
        for item in CashFlowLineItem.allCases {
            switch item {
            case .cashAtBeginningOfPeriod:
                if matchingCashScope { result.amounts[item] = previous.value(.cashAtEndOfPeriod) }
            case .cashAtEndOfPeriod:
                result.amounts[item] = current.value(item)
            case .changeInCash, .effectOfExchangeRates:
                if matchingCashScope, let end = current.value(item), let start = previous.value(item) {
                    result.amounts[item] = end - start
                }
            default:
                if let currentConcepts = current.sourceConcepts?[item],
                   let previousConcepts = previous.sourceConcepts?[item], currentConcepts != previousConcepts {
                    continue
                }
                if let end = current.value(item), let start = previous.value(item) {
                    result.amounts[item] = end - start
                    result.sourceConcepts?[item] = current.sourceConcepts?[item]
                }
            }
        }
        if let end = current.sourceFreeCashFlow, let start = previous.sourceFreeCashFlow {
            result.sourceFreeCashFlow = end - start
        }
        return result
    }

    /// Income and some adjustments can also be filed for the standalone
    /// quarter. Prefer those exact disclosures to cumulative subtraction,
    /// including when no prior cumulative adjustment was tagged.
    static func secQuarterCashFlowDetails(
        current: CashFlowDetails, namespace: [String: SECFact],
        anchor: AnchorPeriod, previous: AnchorPeriod, asOf filed: String
    ) -> CashFlowDetails {
        let preceding = secCashFlowDetails(namespace: namespace, anchor: previous, asOf: filed)
        var result = quarterCashFlowDetails(current: current, previous: preceding)
        guard let start = cashDateShift(previous.entry.end, days: 1) else { return result }
        let quarter = AnchorPeriod(entry: SECFactValue(start: start, end: anchor.entry.end, value: 0,
            fiscalYear: anchor.entry.fiscalYear, fiscalPeriod: anchor.entry.fiscalPeriod,
            form: anchor.entry.form, filed: anchor.entry.filed, frame: nil,
            accession: anchor.entry.accession), unit: anchor.unit, kind: .quarterly)
        let direct = secCashFlowDetails(namespace: namespace, anchor: quarter, asOf: filed)
        for item in CashFlowLineItem.allCases {
            switch item {
            case .cashAtBeginningOfPeriod, .cashAtEndOfPeriod:
                continue
            case .effectOfExchangeRates, .changeInCash:
                guard direct.cashIncludesRestrictedCash == result.cashIncludesRestrictedCash else { continue }
            default:
                break
            }
            guard let value = direct.value(item) else { continue }
            // A standalone component cannot replace a complete quarter total
            // already obtained from compatible cumulative disclosures.
            if direct.isPartial(item), result.value(item) != nil, !result.isPartial(item) { continue }
            result.amounts[item] = value
            result.sourceConcepts?[item] = direct.sourceConcepts?[item]
            if direct.isPartial(item) {
                if result.partialItems == nil { result.partialItems = [] }
                result.partialItems?.insert(item)
            } else {
                result.partialItems?.remove(item)
            }
        }
        return result
    }

    private static func cashDetailValue(_ concepts: [String], namespace: [String: SECFact],
                                       anchor: AnchorPeriod, asOf filed: String) -> (concept: String, value: Double)? {
        let candidates = concepts.enumerated().flatMap { rank, concept in
            (namespace[concept]?.units[anchor.unit] ?? []).filter {
                $0.start == anchor.entry.start && $0.end == anchor.entry.end
                    && ($0.filed ?? "") <= filed && $0.value.isFinite
            }.map { (rank: rank, concept: concept, entry: $0) }
        }
        guard let match = candidates.sorted(by: {
            if $0.entry.filed != $1.entry.filed { return ($0.entry.filed ?? "") > ($1.entry.filed ?? "") }
            return $0.rank < $1.rank
        }).first else { return nil }
        return (match.concept, match.entry.value)
    }

    private static func cashDetailInstant(_ concepts: [String], namespace: [String: SECFact],
                                         unit: String, end: String, asOf filed: String) -> Double? {
        for concept in concepts {
            let values = (namespace[concept]?.units[unit] ?? []).filter {
                $0.start == nil && $0.end == end && ($0.filed ?? "") <= filed && $0.value.isFinite
            }.sorted { ($0.filed ?? "") > ($1.filed ?? "") }
            if let value = values.first?.value { return value }
        }
        return nil
    }

    private static func cashDateBefore(_ date: String) -> String? { cashDateShift(date, days: -1) }

    private static func cashDateShift(_ date: String, days: Int) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: date) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: days, to: parsed).map(formatter.string)
    }
}
