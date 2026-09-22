import XCTest
import SwiftUI
@testable import CatfolioIOS

final class ManagementDeliveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_257_600) // September 2026
    private let quote = "Our GAAP company revenue for FY2025 Q2 will be at least USD 10 billion and net income at least USD 2 billion."

    private func target(metric: String = "revenue", period: String = "Q2", currency: String = "USD", basis: String = "GAAP",
                        scope: String = "company", comparison: String = "atLeast", lower: String = "10", upper: String = "",
                        scale: String = "billion") -> ManagementTarget {
        .init(metric: metric, fiscalYear: 2025, period: period, currency: currency, basis: basis, scope: scope,
            comparison: comparison, lower: lower, upper: upper, scale: scale)
    }

    private func promise(targets: [ManagementTarget]? = nil, quote: String? = nil, numeric: Bool = true,
                         deadline: String = "2025-06-30") -> ManagementPromise {
        .init(id: "p1", sourceID: "call", title: "收入与利润承诺", quote: quote ?? self.quote,
            deadline: deadline, numeric: numeric, targets: targets ?? [target()])
    }

    private func documents(revenue: Double = 11e9, netIncome: Double = 3e9, published: String = "2025-07-25") -> [ManagementDocument] {
        let facts: [ManagementFact] = [("revenue", revenue), ("netIncome", netIncome)].map { metric, value in
            .init(id: metric, metric: metric, fiscalYear: 2025, period: "Q2", periodEnd: "2025-06-30", currency: "USD",
                value: value, sourceID: "financials", quote: "\(metric): \(value) USD; GAAP company; FY2025 Q2; period ending 2025-06-30.")
        }
        return [
            .init(id: "call", kind: .transcript, fiscalYear: 2025, period: "Q1", published: "2025-04-25",
                title: "TEST FY2025 Q1 · Test fixture", url: URL(string: "https://example.com/call")!, text: quote, facts: []),
            .init(id: "financials", kind: .financials, fiscalYear: 2025, period: "Q2", published: published,
                title: "TEST FY2025 Q2 · Test fixture", url: URL(string: "https://example.com/report")!, text: facts.map(\.quote).joined(separator: "\n"), facts: facts)
        ]
    }

    func testNumericThresholdAndAboveGuidance() {
        for value in [10e9, 11e9] {
            let result = ManagementDeliveryRules.evaluate(promise(), documents: documents(revenue: value), now: now)
            XCTAssertEqual(result.status, .delivered)
            XCTAssertEqual(result.method, "rules")
            XCTAssertEqual(result.evidence.first?.sourceID, "financials")
        }
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(), documents: documents(revenue: 10e9 - 1), now: now).status, .missed)
    }

    func testPartialRequiresActualPassAndFail() {
        let p = promise(targets: [target(), target(metric: "netIncome", lower: "2")])
        XCTAssertEqual(ManagementDeliveryRules.evaluate(p, documents: documents(netIncome: 1e9), now: now).status, .partial)
        XCTAssertEqual(ManagementDeliveryStatus.aggregate([.delivered, .pending]), .pending)
        XCTAssertEqual(ManagementDeliveryStatus.aggregate([]), .pending)
    }

    func testDifferentBasisCurrencyPeriodOrSegmentCannotBeScored() {
        for t in [target(basis: "nonGAAP"), target(basis: "unknown"), target(currency: "EUR"), target(period: "FY"), target(scope: "segment"), target(metric: "ebitda")] {
            XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(targets: [t]), documents: documents(), now: now).status, .pending)
        }
    }

    func testMissingEvidenceAndFutureOrEarlierPublicationsStayPending() {
        for docs in [Array(documents().prefix(1)), documents(published: "2027-07-25"), documents(published: "2025-04-20")] {
            XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(), documents: docs, now: now).status, .pending)
        }
    }

    func testConflictingFinancialReportsStayPending() {
        var docs = documents()
        docs.append(documents(revenue: 9e9)[1])
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(), documents: docs, now: now).status, .pending)
    }

    func testFabricatedQuoteAndNumericLiteralAreRejected() {
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(quote: "Management promised USD 500 billion revenue."), documents: documents(), now: now).status, .pending)
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(targets: [target(lower: "9")]), documents: documents(), now: now).status, .pending)
        XCTAssertNil(ManagementDeliveryRules.number("1", quote: "USD 10 billion", scale: "billion"))
        XCTAssertNil(ManagementDeliveryRules.number("10", quote: "USD -10 billion", scale: "billion"))
        XCTAssertEqual(ManagementDeliveryRules.number("2", quote: "GAAP EPS will be USD 2.", scale: "units"), 2)
        XCTAssertNil(ManagementDeliveryRules.number("10", quote: "USD 10 million", scale: "billion"))
        XCTAssertEqual(ManagementDeliveryRules.number("1,250.5", quote: "USD 1,250.5 million", scale: "million"), 1_250_500_000)
    }

    func testRangeAndCeilingRules() {
        let text = "Our GAAP company revenue for FY2025 Q2 will be between USD 10 and 12 billion."
        var docs = documents()
        let original = docs.removeFirst()
        docs.insert(.init(id: original.id, kind: .transcript, fiscalYear: 2025, period: "Q1", published: original.published,
            title: original.title, url: original.url, text: text, facts: []), at: 0)
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(targets: [target(comparison: "between", upper: "12")], quote: text), documents: docs, now: now).status, .delivered)
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(targets: [target(comparison: "atMost", lower: "", upper: "10")], quote: text), documents: docs, now: now).status, .missed)
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(targets: [target(comparison: "between", lower: "12", upper: "10")], quote: text), documents: docs, now: now).status, .pending)
    }

    func testProtectedArchiveRoundTripAndLanguageIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ManagementDeliveryFiles(directory: directory)
        let archive = ManagementDeliveryArchive(ticker: "TEST", downloadedAt: now, requestedQuarters: 4, documents: documents(), report: nil)
        try await files.save(archive, language: "en")
        let restored = await files.load(ticker: "TEST", quarters: 4, language: "en")
        XCTAssertEqual(restored?.documents.count, 2)
        let otherLanguage = await files.load(ticker: "TEST", quarters: 4, language: "zh")
        XCTAssertNil(otherLanguage)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)[0]
        #if !targetEnvironment(simulator)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType, .complete)
        #endif
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try await files.remove(ticker: "TEST", quarters: 4, language: "en")
        let removed = await files.load(ticker: "TEST", quarters: 4, language: "en")
        XCTAssertNil(removed)
    }

    func testNumericDeadlineAndEPSScaleCannotBeChanged() {
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(deadline: "2025-05-01"), documents: documents(), now: now).status, .pending)
        XCTAssertEqual(ManagementDeliveryRules.evaluate(promise(targets: [target(metric: "eps", scale: "billion")]), documents: documents(), now: now).status, .pending)
    }

    func testQualitativeExplicitNaturalDateCanBeVerified() async throws {
        let p = promise(targets: [], quote: "We will launch the new product by June 30, 2025.", numeric: false)
        let doc = ManagementDocument(id: "later", kind: .transcript, fiscalYear: 2025, period: "Q2", published: "2025-07-25",
            title: "TEST", url: URL(string: "https://example.com")!, text: "We launched the new product on June 5, 2025.", facts: [])
        let analyzer = ManagementDeliveryAnalyzer(answer: { _ in
            #"{"status":"delivered","quote":"We launched the new product on June 5, 2025.","eventDate":"2025-06-05","explanation":"Launched before the original deadline."}"#
        })
        let result = try await analyzer.qualitative(p, original: documents()[0], all: ManagementDeliveryAnalyzer.chunks(doc), language: "en", now: now)
        XCTAssertEqual(result.status, .delivered)
        XCTAssertEqual(result.evidence.first?.sourceID, "later")
        XCTAssertFalse(ManagementDeliveryAnalyzer.hasExplicitDate("2025-06-05", in: "We launched on June 5."))
    }

    func testCancellationStopsFurtherAIWork() async throws {
        let analyzer = ManagementDeliveryAnalyzer(answer: { _ in throw CancellationError() })
        let archive = ManagementDeliveryArchive(ticker: "TEST", downloadedAt: now, requestedQuarters: 4, documents: documents(), report: nil)
        do {
            _ = try await analyzer.analyze(archive, language: "en", now: now, progress: { _ in })
            XCTFail("Cancellation must propagate without publishing a report")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAnalysisUsesRuleVerdictAndRejectsInventedExtraction() async throws {
        let p = promise()
        let invented = promise(quote: "This is an invented future promise that does not exist.")
        let payload = String(data: try JSONEncoder().encode(["promises": [p, invented]]), encoding: .utf8)!
        let analyzer = ManagementDeliveryAnalyzer(answer: { prompt in
            prompt.contains("Extract up to") ? payload : #"{"summary":"One verified numeric promise. Coverage is limited to the downloaded documents."}"#
        })
        let archive = ManagementDeliveryArchive(ticker: "TEST", downloadedAt: now, requestedQuarters: 4, documents: documents(), report: nil)
        let report = try await analyzer.analyze(archive, language: "en", now: now, progress: { _ in })
        XCTAssertEqual(report.assessments.count, 1)
        XCTAssertEqual(report.assessments[0].status, .delivered)
        XCTAssertEqual(report.assessments[0].promise.sourceID, "call")
        XCTAssertTrue(report.warnings.count >= 3)
    }

    func testQualitativeAbsenceOrLateEventDoesNotBecomeDelivered() async throws {
        let p = promise(targets: [], numeric: false)
        for response in [#"{"status":"pending","quote":"","eventDate":"","explanation":""}"#,
                         #"{"status":"delivered","quote":"We launched the product on 2025-07-01.","eventDate":"2025-07-01","explanation":"Late"}"#] {
            let analyzer = ManagementDeliveryAnalyzer(answer: { _ in response })
            let doc = ManagementDocument(id: "later", kind: .transcript, fiscalYear: 2025, period: "Q2", published: "2025-07-25",
                title: "TEST", url: URL(string: "https://example.com")!, text: "Our company revenue increased. We launched the product on 2025-07-01.", facts: [])
            let result = try await analyzer.qualitative(p, original: documents()[0], all: ManagementDeliveryAnalyzer.chunks(doc), language: "en", now: now)
            XCTAssertEqual(result.status, .pending)
        }
    }

    func testChunkingCoversEntireDocumentWithBoundedOverlap() {
        let text = String(repeating: "a", count: 10_000) + "FINAL_SENTINEL"
        let doc = ManagementDocument(id: "test", kind: .transcript, fiscalYear: 2025, period: "Q1", published: "2025-04-25",
            title: "Test", url: URL(string: "https://example.com")!, text: text, facts: [])
        let chunks = ManagementDeliveryAnalyzer.chunks(doc)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 4_200 })
        XCTAssertTrue(chunks.last!.text.hasSuffix("FINAL_SENTINEL"))
    }

    @MainActor func testResultsRenderAtIPhoneWidth() throws {
        var pendingPromise = promise(targets: [target(basis: "nonGAAP")])
        pendingPromise.id = "pending-promise"
        let assessments = [ManagementDeliveryRules.evaluate(promise(), documents: documents(), now: now),
                           ManagementDeliveryRules.evaluate(pendingPromise, documents: documents(), now: now)]
        let report = ManagementDeliveryReport(ticker: "TEST", language: "zh-Hans", generatedAt: now, requestedQuarters: 4, transcriptCount: 4,
            summary: "测试样例：收入承诺已兑现；调整后指标仍待验证。", assessments: assessments,
            warnings: ["仅为界面测试样例，不是真实公司分析。"])
        for width: CGFloat in [320, 393] {
            let content = ManagementDeliveryResults(report: report, documents: documents(), initiallyExpanded: width == 393 ? ["p1"] : [], openSource: { _ in })
                .padding(20).frame(width: width).background(Color(uiColor: .systemBackground))
            let controller = UIHostingController(rootView: content.ignoresSafeArea())
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 2_000))
            XCTAssertLessThan(size.height, 2_000)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = controller
            window.isHidden = false
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
            window.isHidden = true
            let attachment = XCTAttachment(image: image)
            attachment.name = "ManagementDelivery-\(Int(width))-fixture"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// A release's outlook, read without a model: the period in the issuer's
    /// own fiscal terms, the number exactly as printed, company-wide only.
    func testGuidanceIsReadFromAReleaseOutlook() throws {
        let text = """
        NVIDIA Announces Financial Results for Second Quarter Fiscal 2027
        Revenue of $96.2 billion, up 106% from a year ago

        Outlook
        NVIDIA’s outlook for the third quarter of fiscal 2027 is as follows:
        • Revenue is expected to be $108.0 billion, plus or minus 2%.
        • Data Center revenue is expected to be $89.0 billion.
        • GAAP and non-GAAP gross margins are expected to be 74.0%, plus or minus 50 basis points.

        Highlights
        Second-quarter revenue was $89.0 billion, up 18% from the previous quarter.
        """
        let release = ManagementDocument(id: "release-2027-Q2", kind: .transcript, fiscalYear: 2027, period: "Q2",
                                         published: "2026-08-26", title: "NVDA", url: URL(string: "https://www.sec.gov")!,
                                         text: text, facts: [])
        let promises = ManagementDeliveryRules.guidancePromises(in: release)
        XCTAssertEqual(promises.count, 1, "Segment and margin lines are not company revenue guidance")
        let target = try XCTUnwrap(promises.first?.targets.first)
        XCTAssertEqual(target.metric, "revenue")
        XCTAssertEqual(target.fiscalYear, 2027)
        XCTAssertEqual(target.period, "Q3")
        XCTAssertEqual(target.lower, "108.0")
        XCTAssertEqual(target.scale, "billion")
        XCTAssertEqual(target.comparison, "atLeast")
        XCTAssertTrue(ManagementDeliveryRules.containsQuote(try XCTUnwrap(promises.first).quote, in: text))
        // Nothing to find in a release without an outlook.
        let plain = ManagementDocument(id: "r", kind: .transcript, fiscalYear: 2026, period: "Q3", published: "2026-07-30",
                                       title: "AAPL", url: URL(string: "https://www.sec.gov")!,
                                       text: "Apple reports third quarter results. Revenue was $94.0 billion.", facts: [])
        XCTAssertTrue(ManagementDeliveryRules.guidancePromises(in: plain).isEmpty)
    }
}
