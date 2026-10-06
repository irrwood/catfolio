import Foundation

// AI context, attention analysis and ETF look-through.
// Shared observable state remains owned by AppModel.
extension AppModel {
    func loadBriefing() async throws -> String {
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        return try await LocalAIClient().briefing(document: scoped)
    }

    func askAI(_ question: String, attentionContext: String? = nil) async throws -> String {
        let scope = comparisonCacheScope
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        guard scope == comparisonCacheScope else { throw CancellationError() }
        return try await LocalAIClient().answer(
            question,
            document: scoped,
            additionalContext: computedAIContext(for: scoped, attentionContext: attentionContext)
        )
    }

    /// `askAI`, delivered as the model writes it.
    func streamAI(_ question: String, attentionContext: String? = nil, webSearch: Bool = false) async throws -> AsyncThrowingStream<AIStreamEvent, Error> {
        let scope = comparisonCacheScope
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        guard scope == comparisonCacheScope else { throw CancellationError() }
        return LocalAIClient().streamAnswer(
            question,
            document: scoped,
            additionalContext: computedAIContext(for: scoped, attentionContext: attentionContext),
            webSearch: webSearch
        )
    }

    private func computedAIContext(for scoped: LocalPortfolioDocument, attentionContext: String?) -> String {
        var sections: [String] = []
        if presentedSource == portfolioSource,
           Set(document.accounts.map(\.id)) == Set(scoped.accounts.map(\.id)) {
            sections.append(AIComputedContext.build(
                overview: overview, holdings: holdings, dailyChanges: holdingDailyChanges,
                realisedProfit: realisedProfit, realisedProfitGaps: realisedProfitGaps,
                comparison: comparison, analytics: returnsAnalytics,
                updatedAt: localUpdatedAt, cachedAt: portfolioCachedAt))
        }
        if let attentionContext, !attentionContext.isEmpty {
            sections.append("上一次 Portfolio Attention 的结果（保留信号、thesis 与 confidence）：\n" + attentionContext)
        }
        return sections.joined(separator: "\n\n")
    }

    func rejudgeAttention(_ row: PortfolioAttentionHolding, supporting: [String], counter: [String],
                          notes: [String]) async throws -> PortfolioAttentionThesis {
        try await LocalAIClient().rejudgeAttention(row: row, supporting: supporting, counter: counter, notes: notes)
    }

    func followUpAttention(_ row: PortfolioAttentionHolding, question: String,
                           history: [PortfolioAttentionFollowUp]) async throws -> (text: String, searched: Bool) {
        try await LocalAIClient().followUpAttention(row: row, question: question, history: history)
    }

    func portfolioAttention() async throws -> PortfolioAttentionReport {
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        return try await LocalAIClient().portfolioAttention(document: scoped)
    }

    func loadETFLookThrough(basis: ETFLookThroughBasis) async throws -> ETFLookThroughResponse {
        let snapshot: LocalPortfolioDocument
        if presentedSource == portfolioSource {
            snapshot = document
        } else {
            snapshot = await selectedDocument(from: try await loadActiveDocument())
        }
        let preparation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let response = try LocalETFLookThrough.make(document: snapshot, basis: basis)
            try Task.checkCancellation()
            return response
        }
        return try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

}
