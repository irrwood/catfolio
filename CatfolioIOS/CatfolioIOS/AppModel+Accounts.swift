import Foundation

// Account selection actions, ledger edits and broker/CSV imports.
// Shared observable state remains owned by AppModel.
extension AppModel {
    func selectBroker(_ provider: BrokerProvider) {
        storedActiveBroker = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.brokerKey)
    }

    func selectAllAccounts() async {
        await updateAccountSelection(Set(accounts.map(\.id)), selectsAll: true)
    }

    func toggleAccount(_ accountID: String) async {
        // Read the latest requested keys: a second tap can arrive before the
        // first selection has finished publishing its new presentation.
        var next = requestedAccountKeysFromDisplayedAccounts()
        if next.contains(accountID) {
            guard next.count > 1 else { return }
            next.remove(accountID)
        } else {
            next.insert(accountID)
        }
        await updateAccountSelection(next, selectsAll: false)
    }

    func transactions(for accountID: String) async throws -> [LocalTransactionRecord] {
        let loaded = try await loadActiveDocument()
        return (loaded.transactions ?? [])
            .filter { $0.accountKey == accountID }
            .sorted {
                if $0.date == $1.date { return $0.id < $1.id }
                return $0.date > $1.date
            }
    }

    func activityLedger() async throws -> PortfolioActivityLedger {
        let loaded = try await loadActiveDocument()
        // Off the main actor: sorting a long history there held up the push
        // of the page that asked for it.
        return await Task.detached(priority: .userInitiated) {
            let names = loaded.positions.reduce(into: [String: String]()) { result, position in
                let key = position.ticker.uppercased()
                if result[key] == nil || result[key] == key {
                    result[key] = position.name.isEmpty ? key : position.name
                }
            }
            return PortfolioActivityLedger(
                accounts: loaded.accounts,
                transactions: (loaded.transactions ?? []).sorted { lhs, rhs in
                    if lhs.date == rhs.date {
                        return (lhs.tradeID ?? lhs.ticker) > (rhs.tradeID ?? rhs.ticker)
                    }
                    return lhs.date > rhs.date
                },
                securityNames: names
            )
        }.value
    }

    /// Creates the account up front so a broker connection is visible and
    /// editable while its first report is still being generated.
    func registerPendingAccount(
        id: String, source: String, name: String, baseCurrency: String
    ) async throws {
        let saved = try await LocalPortfolioStore.shared.registerAccount(
            PortfolioAccount(
                id: id, accountID: nil, source: source, name: name,
                baseCurrency: baseCurrency, positionCount: 0, transactionCount: 0,
                manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0
            )
        )
        try await apply(activeDocument(from: saved))
    }

    func renameAccount(_ accountID: String, to name: String) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else { return }
        _ = try await LocalPortfolioStore.shared.renameAccount(accountID, to: name)
        await refreshPortfolio()
    }

    /// Stores which Trading 212 product an account is. The API never reports
    /// it, so this is the only source for the account detail's type row.
    func setTrading212AccountType(_ accountType: Trading212AccountType, for accountKey: String) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else { return }
        _ = try await LocalPortfolioStore.shared.setAccountTypeOverride(accountType.rawValue, for: accountKey)
        await refreshPortfolio()
    }

    func addHistoricalTransaction(
        to account: PortfolioAccount,
        date: Date,
        action: String,
        ticker: String,
        quantity: Double,
        price: Double,
        currency: String
    ) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else { return }
        let transaction = LocalTransactionRecord(
            date: DayDateCodec.string(from: date),
            action: action.uppercased(),
            ticker: ticker.uppercased(),
            quantity: quantity,
            price: price,
            currency: currency.uppercased(),
            source: account.source,
            accountID: account.accountID,
            accountName: account.name,
            entryMethod: "manual"
        )
        _ = try await LocalPortfolioStore.shared.appendHistoricalTransaction(transaction)
        await refreshPortfolio()
        await refreshReturnsPage()
    }

    func deduplicateTransactions(for accountID: String) async throws -> Int {
        guard !isFakeDataMode && !isPublicInvestorMode else { return 0 }
        let (_, removed) = try await LocalPortfolioStore.shared.deduplicateTransactions(for: accountID)
        if removed > 0 {
            await refreshPortfolio()
            await refreshReturnsPage()
        }
        return removed
    }

    func deleteAccount(_ accountID: String) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else { return }
        invalidateInFlightRequests()
        _ = try await LocalPortfolioStore.shared.removeAccount(accountID)
        await presentationCache.removePersonal()
        sourcePresentations.removeValue(forKey: .personal)
        await refreshPortfolio()
        if !accounts.isEmpty {
            await refreshReturnsPage()
        }
    }

    func resetLocalPortfolio() async throws {
        portfolioSourceGeneration &+= 1
        portfolioSourceTask?.cancel()
        portfolioSourceTask = nil
        invalidateInFlightRequests()
        returnsPageTask?.cancel()
        returnsPageRequestGeneration &+= 1
        let backup = try await personalDocumentResetter()
        await presentationCache.removePersonal()
        // The explicit reset action must not restore an old personal screen.
        // Shared public-data caches and built-in account snapshots stay intact.
        sourcePresentations.removeValue(forKey: .personal)
        holdingDetailContent = holdingDetailContent.filter { $0.key.source != .personal }
        holdingDetailContentOrder.removeAll { $0.source == .personal }
        presentedSource = nil
        storedFakeDataMode = false
        modeDefaults.set(false, forKey: Self.fakeDataModeKey)
        modeDefaults.removeObject(forKey: Self.selectedAccountsKey)
        modeDefaults.removeObject(forKey: Self.selectsAllAccountsKey)
        document = .empty
        updateRealisedProfit(from: document)
        fullDocument = .empty
        overview = nil
        portfolioChart = nil
        isPortfolioChartLoading = false
        holdings = []
        accounts = []
        storedSelectedAccountKeys = []
        holdingDailyChanges = [:]
        holdingDailyChangesSignature = ""
        comparison = nil
        returnsAnalytics = nil
        comparisonWarning = nil
        analyticsWarning = nil
        portfolioFailure = nil
        returnsError = nil
        localSource = "尚未导入"
        localUpdatedAt = nil
        portfolioCachedAt = nil
        portfolioChartRevision &+= 1
        comparisonRevision &+= 1
        returnsAnalyticsRevision &+= 1
        portfolioRecoveryNotice = backup.map {
            L10n.text("本机组合已重置，原数据备份为 \($0.lastPathComponent)。券商授权和 AI 对话已保留。")
        } ?? L10n.text("本机组合已重置。券商授权和 AI 对话已保留。")
    }

    func suggestedAccountNickname(detectedName: String? = nil) -> String {
        if let detectedName {
            let detected = detectedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detected.isEmpty { return detected }
        }
        return Self.nextGeneratedNickname(usedNames: Set(accounts.map(\.displayName)))
    }

    func accountNames(
        source: String,
        accountIDs: [String],
        preferredNickname: String,
        targetAccountID: String? = nil
    ) -> [String: String] {
        let provider = AccountNaming.providerName(for: source)
        let existing = Dictionary(uniqueKeysWithValues: accounts
            .filter { $0.source == source }
            .compactMap { account in account.accountID.map { ($0, account.name) } })
        var usedNames = Set(accounts.map(\.displayName))
        var result: [String: String] = [:]
        var usedPreferredNickname = false

        for accountID in Array(Set(accountIDs)).sorted() {
            if accountID != targetAccountID, let existingName = existing[accountID] {
                result[accountID] = existingName
                usedNames.insert(existingName)
                continue
            }
            let nickname: String
            if !usedPreferredNickname,
               !preferredNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nickname = preferredNickname
                usedPreferredNickname = true
            } else {
                nickname = Self.nextGeneratedNickname(usedNames: usedNames)
            }
            let displayName = AccountNaming.displayName(provider: provider, nickname: nickname)
            result[accountID] = displayName
            usedNames.insert(displayName)
        }
        return result
    }

    func importCSV(
        _ data: Data,
        filename _: String,
        accountID: String? = nil,
        accountName: String? = nil,
        source: String = "CSV",
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        let isins = await Task.detached(priority: .userInitiated) {
            LocalCSVImporter.isinRequests(in: data)
        }.value
        let resolved = isins.isEmpty ? [:] : await SecurityIdentityResolver.shared.tickers(forISINs: isins)
        let (namedPositions, namedTransactions, result) = try await Task.detached(priority: .userInitiated) {
            let (positions, transactions, result) = try LocalCSVImporter.parse(data, resolvedISINs: resolved)
            guard let accountName else { return (positions, transactions, result) }
            return (
                positions.map { $0.assignedAccount(id: accountID, name: accountName, source: source) },
                transactions.map { $0.assignedAccount(id: accountID, name: accountName, source: source) },
                result
            )
        }.value
        invalidateInFlightRequests()
        let generation = portfolioRequestGeneration
        let saved = try await LocalPortfolioStore.shared.replace(
            positions: namedPositions,
            source: source,
            transactions: namedTransactions,
            replacingAccountsOnly: replacingAccountsOnly
        )
        try await apply(activeDocument(from: saved))
        await enrichPortfolioChart(from: document, generation: generation)
        return result
    }

    func importTrading212(
        _ snapshot: Trading212Snapshot,
        accountNames: [String: String] = [:],
        accountTypeOverrides: [String: String] = [:],
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        var warnings: [String] = []
        // Trading 212 never reports whether an account is an ISA. A sync that
        // does not carry a freshly chosen type must keep the stored one, since
        // nothing else on the device knows it.
        let storedTypes = Dictionary(
            accounts.filter { $0.source == "Trading 212" }
                .compactMap { account in
                    account.accountID.flatMap { id in account.accountTypeOverride.map { (id, $0) } }
                },
            uniquingKeysWith: { _, last in last }
        )
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.quantity > 0 else { return nil }
            guard let average = position.averagePricePaid, average > 0 else {
                warnings.append(L10n.text("\(position.rawTicker) 缺少平均成本，已跳过"))
                return nil
            }
            return LocalPositionRecord(
                ticker: position.ticker, name: position.name, shares: position.quantity,
                averageCost: average, currency: position.currency,
                quotePrice: position.currentPrice ?? average, quoteCurrency: position.currency,
                source: "Trading 212",
                openedDate: position.createdAt.map { String($0.prefix(10)) },
                accountID: "account-\(position.accountSlot)",
                accountName: accountNames["account-\(position.accountSlot)"]
                    ?? L10n.text("账户 \(position.accountSlot)"),
                accountCurrency: position.accountCurrency ?? "GBP",
                brokerPnl: position.ppl,
                brokerPnlCurrency: position.ppl == nil ? nil : (position.accountCurrency ?? "GBP"),
                // Trading 212 returns fxPpl in the account currency. Keep the
                // broker value even if currency discovery used its desktop-
                // compatible fallback; dropping it here made iOS show “暂无”.
                brokerFxPnl: position.fxPpl,
                brokerFxPnlCurrency: position.fxPpl == nil ? nil : (position.accountCurrency ?? "GBP"),
                fxPnl: position.fxPpl,
                fxPnlCurrency: position.fxPpl == nil ? nil : (position.accountCurrency ?? "GBP"),
                fxPnlStatus: position.fxPpl == nil ? nil : "broker_reported",
                fxPnlSource: position.fxPpl == nil ? nil : "trading212_wallet_impact"
            )
        }
        if !snapshot.hasCompleteTransactionHistory {
            warnings.append(
                snapshot.transactionHistoryStatus
                    ?? L10n.text("成交历史正在分页同步，稍后再次同步会继续补全。")
            )
        }
        let transactions = snapshot.transactions.map { transaction in
            LocalTransactionRecord(
                date: transaction.date,
                action: transaction.action,
                ticker: transaction.ticker,
                quantity: transaction.quantity,
                price: transaction.price,
                currency: transaction.currency,
                source: "Trading 212",
                accountID: "account-\(transaction.accountSlot)",
                accountName: accountNames["account-\(transaction.accountSlot)"]
                    ?? L10n.text("账户 \(transaction.accountSlot)"),
                tradeID: transaction.reference,
                brokerFXRate: transaction.brokerFXRate,
                realisedProfitLoss: transaction.realisedProfitLoss,
                realisedProfitLossCurrency: transaction.realisedProfitLossCurrency,
                executedAt: transaction.executedAt
            )
        }
        let enriched = await LocalFXImpactCalculator().enrich(
            positions: positions,
            transactions: transactions
        )
        let unavailableFXCount = enriched.filter { $0.fxPnlStatus == "unavailable" }.count
        if unavailableFXCount > 0 {
            warnings.append(L10n.text("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算"))
        }
        let result = try await replace(
            enriched,
            source: "Trading 212",
            warnings: warnings,
            transactions: snapshot.hasCompleteTransactionHistory ? transactions : nil,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: snapshot.syncedAccounts.map { account in
                let accountTypeOverride = account.accountID.flatMap { id in
                    accountTypeOverrides[id] ?? storedTypes[id]
                }
                return PortfolioAccount(
                    id: account.id, accountID: account.accountID, source: account.source,
                    name: account.accountID.flatMap { accountNames[$0] } ?? account.name,
                    baseCurrency: account.baseCurrency, positionCount: account.positionCount,
                    transactionCount: account.transactionCount,
                    manualTransactionCount: account.manualTransactionCount,
                    hasCSVImport: account.hasCSVImport, marketValueUSD: account.marketValueUSD,
                    accountTypeOverride: accountTypeOverride
                )
            }
        )
        if !snapshot.hasCompleteTransactionHistory, !transactions.isEmpty {
            invalidateInFlightRequests()
            let generation = portfolioRequestGeneration
            let merged = try await LocalPortfolioStore.shared.mergeTransactions(transactions)
            try await apply(activeDocument(from: merged))
            await enrichPortfolioChart(from: document, generation: generation)
        }
        return result
    }

    func importMoomoo(
        _ snapshot: MoomooSnapshot,
        accountNames preferredAccountNames: [String: String] = [:],
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        var warnings = snapshot.historyWarnings
        let accountNames = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { account in
            let visibleID = account.accountCardNumber.isEmpty ? account.accountID : account.accountCardNumber
            return (
                account.accountID,
                preferredAccountNames[account.accountID]
                    ?? Self.maskedAccountName(provider: "Moomoo", accountID: visibleID)
            )
        })
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.positionSide.uppercased() != "SHORT", position.quantityValue > 0 else { return nil }
            guard let average = position.costPriceValue, average > 0 else {
                warnings.append(L10n.text("\(position.code) 缺少有效成本价，已跳过"))
                return nil
            }
            return LocalPositionRecord(
                ticker: Self.moomooTicker(position.code), name: position.stockName,
                shares: position.quantityValue, averageCost: average,
                currency: position.currency.uppercased(), quotePrice: position.nominalPriceValue ?? average,
                quoteCurrency: position.currency.uppercased(), source: "Moomoo",
                openedDate: nil,
                accountID: position.accountID,
                accountName: accountNames[position.accountID] ?? Self.maskedAccountName(provider: "Moomoo", accountID: position.accountID),
                accountCurrency: snapshot.accountCurrencies[position.accountID]
            )
        }
        let positionCurrencies = snapshot.positions.reduce(into: [String: String]()) { result, position in
            result["\(position.accountID)|\(position.code.uppercased())"] = position.currency.uppercased()
        }
        let transactions = snapshot.fills.compactMap { fill -> LocalTransactionRecord? in
            guard fill.quantity > 0, fill.price > 0, !fill.date.isEmpty else { return nil }
            let side = fill.side.uppercased()
            let action: String
            if ["BUY", "BUY_BACK"].contains(side) {
                action = "BUY"
            } else if ["SELL", "SELL_SHORT"].contains(side) {
                action = "SELL"
            } else {
                return nil
            }
            guard let currency = positionCurrencies["\(fill.accountID)|\(fill.code.uppercased())"]
                    ?? fill.quoteCurrency else {
                warnings.append(L10n.text("\(fill.code) 缺少可核实的成交币种，已保留原有历史。"))
                return nil
            }
            return LocalTransactionRecord(
                date: fill.date,
                action: action,
                ticker: Self.moomooTicker(fill.code),
                quantity: fill.quantity,
                price: fill.price,
                currency: currency,
                source: "Moomoo",
                accountID: fill.accountID,
                accountName: accountNames[fill.accountID],
                tradeID: fill.tradeID,
                executedAt: ISO8601DateFormatter().string(from: Date(
                    timeIntervalSince1970: TimeInterval(fill.executedAtMicroseconds) / 1_000_000))
            )
        }
        let enriched = await LocalFXImpactCalculator().enrich(
            positions: positions,
            transactions: transactions
        )
        let unavailableFXCount = enriched.filter { $0.fxPnlStatus == "unavailable" }.count
        if unavailableFXCount > 0 {
            warnings.append(L10n.text("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算"))
        }
        return try await replace(
            enriched,
            source: "Moomoo",
            warnings: warnings,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: snapshot.accounts.map { account in
                PortfolioAccount(
                    id: "Moomoo|\(account.accountID)", accountID: account.accountID, source: "Moomoo",
                    name: accountNames[account.accountID] ?? account.accountCardNumber,
                    baseCurrency: snapshot.accountCurrencies[account.accountID] ?? "USD",
                    positionCount: 0, transactionCount: 0, manualTransactionCount: 0,
                    hasCSVImport: false, marketValueUSD: 0
                )
            },
            mergesTransactionHistory: true
        )
    }

    func importRobinhood(
        _ snapshot: RobinhoodAccountSnapshot,
        context: AccountConnectorContext,
        nickname: String
    ) async throws -> CSVImportResult {
        guard !isFakeDataMode && !isPublicInvestorMode else { throw RobinhoodAccountError.unsupported }
        guard await RobinhoodMCPClient.shared.connectionGeneration() == snapshot.connectionGeneration,
              await RobinhoodMCPClient.shared.isConnected() else { throw RobinhoodAccountError.disconnected }
        try Task.checkCancellation()
        try snapshot.validate(context: context, existing: accounts)
        let name = context.account?.name ?? AccountNaming.displayName(provider: "Robinhood", nickname: nickname)
        return try await replace(
            snapshot.positions.map { $0.renamedAccount(to: name) },
            source: "Robinhood", warnings: [], replacingAccountsOnly: true,
            syncedAccounts: [snapshot.portfolioAccount(name: name)]
        )
    }

    func importSnapTrade(
        _ snapshot: SnapTradeSnapshot,
        context: AccountConnectorContext,
        nickname: String
    ) async throws -> CSVImportResult {
        guard !isFakeDataMode && !isPublicInvestorMode else { throw SnapTradeError.accountUnavailable }
        try snapshot.validate(context: context, existing: accounts)
        let name = context.account?.name ?? AccountNaming.displayName(provider: "SnapTrade", nickname: nickname)
        return try await replace(
            snapshot.positions.map { $0.renamedAccount(to: name) },
            source: "SnapTrade", warnings: [], replacingAccountsOnly: true,
            syncedAccounts: [snapshot.portfolioAccount(name: name)]
        )
    }

    func importIBKR(
        _ snapshot: IBKRFlexSnapshot,
        accountNames: [String: String] = [:],
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        var warnings: [String] = []
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.quantity > 0 else { return nil }
            let category = position.assetCategory.uppercased()
            guard category.isEmpty || category == "STK" else {
                warnings.append(L10n.text("已跳过不受支持的 \(category) 持仓 \(position.symbol)"))
                return nil
            }
            guard let average = position.averageCost, average > 0 else {
                warnings.append(L10n.text("\(position.symbol) 缺少平均成本，已跳过"))
                return nil
            }
            let currency = position.currency.isEmpty ? "USD" : position.currency.uppercased()
            let quote = position.markPrice ?? position.marketValue.map { $0 / position.quantity } ?? average
            return LocalPositionRecord(
                ticker: position.symbol.uppercased(), name: position.name, shares: position.quantity,
                averageCost: average, currency: currency, quotePrice: quote,
                quoteCurrency: currency, source: "IBKR Flex",
                openedDate: position.openDate,
                accountID: position.accountID,
                accountName: accountNames[position.accountID] ?? "IBKR · Individual",
                accountCurrency: snapshot.accountCurrencies[position.accountID],
                quoteObservedAt: snapshot.quoteObservedAt
            )
        }
        let transactions = snapshot.transactions.map { transaction in
            LocalTransactionRecord(
                date: transaction.tradeDate,
                action: transaction.side,
                ticker: transaction.symbol,
                quantity: transaction.quantity,
                price: transaction.price,
                currency: transaction.currency,
                source: "IBKR Flex",
                accountID: transaction.accountID,
                accountName: accountNames[transaction.accountID] ?? "IBKR · Individual",
                tradeID: transaction.tradeID,
                brokerFXRate: transaction.fxRateToBase,
                realisedProfitLoss: transaction.side.uppercased() == "SELL"
                    ? transaction.realisedProfitLoss
                    : nil,
                realisedProfitLossCurrency: transaction.realisedProfitLoss == nil
                    ? nil
                    : transaction.currency
            )
        }
        if snapshot.accountCurrencies.isEmpty {
            warnings.append(L10n.text("Flex Query 缺少 Account Information → Base Currency，汇率影响暂不可计算"))
        }
        if transactions.isEmpty {
            warnings.append(L10n.text("Flex Query 缺少 Trades → Executions；无建仓日时汇率影响将标记为不可算"))
        }
        let enriched = await LocalFXImpactCalculator().enrich(
            positions: positions,
            transactions: transactions
        )
        let unavailableFXCount = enriched.filter { $0.fxPnlStatus == "unavailable" }.count
        if unavailableFXCount > 0 {
            warnings.append(L10n.text("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算"))
        }
        return try await replace(
            enriched,
            source: "IBKR Flex",
            warnings: warnings,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: snapshot.syncedPositionAccountIDs.sorted().map { id in
                PortfolioAccount(
                    id: "IBKR Flex|\(id)", accountID: id, source: "IBKR Flex",
                    name: accountNames[id] ?? snapshot.accountNames[id]
                        ?? Self.maskedAccountName(provider: "IBKR", accountID: id),
                    baseCurrency: snapshot.accountCurrencies[id] ?? "USD",
                    positionCount: 0, transactionCount: 0, manualTransactionCount: 0,
                    hasCSVImport: false, marketValueUSD: 0
                )
            },
            mergesTransactionHistory: true
        )
    }

    func replace(
        _ rawPositions: [LocalPositionRecord],
        source: String,
        warnings: [String],
        transactions: [LocalTransactionRecord]? = nil,
        replacingAccountsOnly: Bool = false,
        syncedAccounts: [PortfolioAccount] = [],
        mergesTransactionHistory: Bool = false
    ) async throws -> CSVImportResult {
        invalidateInFlightRequests()
        let generation = portfolioRequestGeneration
        let positions = Self.merge(rawPositions)
        let saved = try await LocalPortfolioStore.shared.replace(
            positions: positions,
            source: source,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: syncedAccounts,
            mergesTransactionHistory: mergesTransactionHistory
        )
        try await apply(activeDocument(from: saved))
        await enrichPortfolioChart(from: document, generation: generation)
        return CSVImportResult(
            ok: true, holdingsCount: positions.count, transactionsCount: nil,
            backupCreated: false, warnings: warnings,
            holdings: positions.map {
                CSVImportedHolding(ticker: $0.ticker, name: $0.name, shares: $0.shares, averageCost: $0.averageCost, currency: $0.currency)
            }
        )
    }
    static func merge(_ positions: [LocalPositionRecord]) -> [LocalPositionRecord] {
        var grouped: [String: LocalPositionRecord] = [:]
        for position in positions {
            let key = "\(position.accountKey)|\(position.ticker.uppercased())"
            guard let existing = grouped[key], existing.currency == position.currency,
                  existing.quoteCurrency == position.quoteCurrency else {
                grouped[key] = position
                continue
            }
            let shares = existing.shares + position.shares
            guard shares > 0 else { continue }
            grouped[key] = LocalPositionRecord(
                ticker: position.ticker.uppercased(), name: existing.name.isEmpty ? position.name : existing.name, shares: shares,
                averageCost: (existing.averageCost * existing.shares + position.averageCost * position.shares) / shares,
                currency: existing.currency,
                quotePrice: (existing.quotePrice * existing.shares + position.quotePrice * position.shares) / shares,
                quoteCurrency: existing.quoteCurrency, source: existing.source,
                openedDate: [existing.openedDate, position.openedDate].compactMap { $0 }.min(),
                accountID: existing.accountID,
                accountName: existing.accountName,
                accountCurrency: existing.accountCurrency == position.accountCurrency
                    ? existing.accountCurrency
                    : nil,
                brokerPnl: existing.brokerPnlCurrency == position.brokerPnlCurrency
                    ? Self.combinedOptional(existing.brokerPnl, position.brokerPnl)
                    : nil,
                brokerPnlCurrency: existing.brokerPnlCurrency == position.brokerPnlCurrency
                    ? existing.brokerPnlCurrency
                    : nil,
                brokerFxPnl: existing.brokerFxPnlCurrency == position.brokerFxPnlCurrency
                    ? Self.combinedOptional(existing.brokerFxPnl, position.brokerFxPnl)
                    : nil,
                brokerFxPnlCurrency: existing.brokerFxPnlCurrency == position.brokerFxPnlCurrency
                    ? existing.brokerFxPnlCurrency
                    : nil,
                fxPnl: existing.fxPnlCurrency == position.fxPnlCurrency
                    ? Self.combinedOptional(existing.fxPnl, position.fxPnl)
                    : nil,
                fxPnlCurrency: existing.fxPnlCurrency == position.fxPnlCurrency ? existing.fxPnlCurrency : nil,
                fxPnlStatus: existing.fxPnlStatus == position.fxPnlStatus
                    ? existing.fxPnlStatus
                    : "mixed",
                fxPnlSource: existing.fxPnlSource == position.fxPnlSource
                    ? existing.fxPnlSource
                    : [existing.fxPnlSource, position.fxPnlSource].compactMap { $0 }.sorted().joined(separator: " + ")
            )
        }
        return grouped.values.sorted { $0.ticker < $1.ticker }
    }

    private static func combinedOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }

    private static func moomooTicker(_ value: String) -> String {
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return value.uppercased() }
        let market = parts[0].uppercased()
        var code = parts[1].uppercased()
        if ["HK", "SEHK"].contains(market), code.count == 5, code.first == "0" { code.removeFirst() }
        let suffixes = [
            "US": "", "NASDAQ": "", "NYSE": "", "AMEX": "", "ARCA": "",
            "HK": ".HK", "SEHK": ".HK", "SG": ".SI", "SGX": ".SI",
            "JP": ".T", "JA": ".T", "TSE": ".T", "AU": ".AX", "ASX": ".AX",
            "CA": ".TO", "TSX": ".TO", "SH": ".SS", "SZ": ".SZ", "BMS": ".KL",
        ]
        return suffixes[market].map { code + $0 } ?? value.uppercased()
    }
}
