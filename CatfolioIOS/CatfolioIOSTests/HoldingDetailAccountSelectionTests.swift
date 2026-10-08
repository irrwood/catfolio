import XCTest
@testable import CatfolioIOS

@MainActor
final class HoldingDetailAccountSelectionTests: XCTestCase {
    private func context(price: Double = 40, accounts: [String] = ["A", "B"],
                         tradeCount: Int = 2) -> HoldingDetailAccountContext {
        let positions = accounts.enumerated().map { index, account in
            LocalPositionRecord(ticker: "AAA", name: "Example", shares: Double(index + 1) * 5,
                averageCost: 20, currency: "USD", quotePrice: price, quoteCurrency: "USD",
                source: "Test", openedDate: nil, accountID: account, accountName: account,
                accountCurrency: "GBP")
        }
        let trades = (0..<tradeCount).map { index in
            LocalTransactionRecord(date: "2025-01-02", action: "BUY", ticker: "AAA",
                quantity: 1, price: 20, currency: "USD", source: "Test",
                accountID: accounts[index % accounts.count], accountName: nil,
                tradeID: "trade-\(index)")
        }
        let document = LocalPortfolioDocument(source: "test", updatedAt: .distantPast,
            positions: positions, snapshots: [], transactions: trades)
        return HoldingDetailAccountContext(ticker: "AAA", document: document,
            options: positions.map {
                HoldingDetailAccountOption(id: $0.accountKey, displayName: $0.resolvedAccountName,
                    marketValue: $0.shares * price, currency: "USD", marketValueUSD: $0.shares * price)
            })
    }

    func testPreparedSelectionsKeepExistingFinancialResults() async throws {
        let context = context()
        let state = HoldingDetailAccountSelection()
        await state.update(context: context)
        XCTAssertEqual(state.holding, context.holding(for: context.allAccountKeys))
        await state.toggle("Test|B")
        XCTAssertEqual(state.accountKeys, ["Test|A"])
        XCTAssertEqual(state.holding, context.holding(for: ["Test|A"]))
        await state.toggle("Test|A")
        XCTAssertTrue(state.accountKeys.isEmpty)
        XCTAssertNil(state.holding)
        await state.toggle("missing")
        XCTAssertTrue(state.accountKeys.isEmpty)
        await state.selectAll()
        XCTAssertEqual(state.holding, context.holding(for: context.allAccountKeys))
    }

    func testReopeningAndReturningToAnAccountReusePreparation() async {
        let counter = PreparationCounter()
        let state = HoldingDetailAccountSelection { context, keys in
            await counter.prepare(context, keys: keys)
        }
        let context = context()
        await state.update(context: context)
        await state.update(context: context)
        await state.toggle("Test|B")
        await state.selectAll()
        await state.toggle("Test|B")
        for _ in 0..<100 { _ = state.holding }
        let calls = await counter.calls
        XCTAssertEqual(calls, 2, "Opening again, drawing, and revisiting a selection reuse its figures")
    }

    func testRefreshInvalidatesFiguresAndPreservesTheSelection() async {
        let state = HoldingDetailAccountSelection()
        await state.update(context: context())
        await state.toggle("Test|B")
        let refreshed = context(price: 60)
        await state.update(context: refreshed)
        XCTAssertEqual(state.accountKeys, ["Test|A"])
        XCTAssertEqual(state.holding, refreshed.holding(for: ["Test|A"]))
        await state.selectAll()
        let expanded = context(price: 60, accounts: ["A", "B", "C"])
        await state.update(context: expanded)
        XCTAssertEqual(state.accountKeys, expanded.allAccountKeys)
        await state.toggle("Test|A")
        await state.toggle("Test|C")
        await state.update(context: context(accounts: ["A"]))
        XCTAssertTrue(state.accountKeys.isEmpty, "A removed account must not silently select another")
        XCTAssertNil(state.holding)
    }

    func testRapidTapsPublishOnlyTheLatestSelectionAndItsFigures() async {
        let context = context()
        let began = expectation(description: "subset preparation started")
        let gate = PreparationGate()
        let state = HoldingDetailAccountSelection { context, keys in
            if keys == ["Test|A"] {
                await gate.wait(began: began)
            }
            return await Task.detached { context.holding(for: keys) }.value
        }
        await state.update(context: context)
        let pending = Task { await state.toggle("Test|B") }
        await fulfillment(of: [began], timeout: 3)
        XCTAssertEqual(state.accountKeys, context.allAccountKeys)
        XCTAssertEqual(state.holding, context.holding(for: context.allAccountKeys),
                       "Do not publish an account label with the previous account's numbers")
        // The second tap reverses the pending first tap, even before it finishes.
        await state.toggle("Test|B")
        await gate.release()
        await pending.value
        XCTAssertEqual(state.accountKeys, context.allAccountKeys)
        XCTAssertEqual(state.holding, context.holding(for: context.allAccountKeys))
    }

    func testAnOldPreparationCannotReplaceRefreshedOrClearedData() async {
        let began = expectation(description: "old ledger preparation started")
        let gate = PreparationGate()
        let state = HoldingDetailAccountSelection { context, keys in
            if context.document.positions.first?.quotePrice == 40 {
                await gate.wait(began: began)
            }
            return await Task.detached { context.holding(for: keys) }.value
        }
        let original = context()
        let pending = Task { await state.update(context: original) }
        await fulfillment(of: [began], timeout: 3)
        let updated = context(price: 60)
        await state.update(context: updated)
        XCTAssertEqual(state.holding, updated.holding(for: updated.allAccountKeys))
        state.clear(accountKeys: ["closed"])
        await gate.release()
        await pending.value
        XCTAssertNil(state.context)
        XCTAssertNil(state.holding)
        XCTAssertEqual(state.accountKeys, ["closed"])
    }

    func testPreparedReadsAvoidRepeatingALargeLedgerCalculation() async throws {
        let context = context(tradeCount: 4_000)
        let state = HoldingDetailAccountSelection()
        await state.update(context: context)
        let start = CFAbsoluteTimeGetCurrent()
        var legacy: Holding?
        for _ in 0..<8 { legacy = context.holding(for: context.allAccountKeys) }
        let repeated = CFAbsoluteTimeGetCurrent() - start
        let preparedStart = CFAbsoluteTimeGetCurrent()
        var prepared: Holding?
        for _ in 0..<8 { prepared = state.holding }
        let reads = CFAbsoluteTimeGetCurrent() - preparedStart
        XCTAssertEqual(prepared, legacy)
        print(String(format: "[HoldingAccountPreparation] 4000 trades, 8 reads: repeated=%.2fms prepared=%.3fms",
                     repeated * 1000, reads * 1000))
        XCTAssertLessThan(reads, repeated, "Rendering must reuse the prepared figures")
    }
}

private actor PreparationCounter {
    private(set) var calls = 0
    func prepare(_ context: HoldingDetailAccountContext, keys: Set<String>) async -> Holding? {
        calls += 1
        return await Task.detached { context.holding(for: keys) }.value
    }
}

private actor PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(began: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            began.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
