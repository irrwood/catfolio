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

    func testTranscriptDatesSortDeduplicateAndExcludeFuture() throws {
        let data = Data(#"[{"quarter":2,"fiscalYear":2025,"date":"2025-07-25"},{"quarter":"Q1","year":"2025","date":"2025-04-25"},{"quarter":2,"fiscalYear":2025,"date":"2025-07-25"},{"quarter":4,"fiscalYear":2027,"date":"2028-01-20"},{"quarter":9,"fiscalYear":2025,"date":"2025-08-20"}]"#.utf8)
        let rows = try JSONDecoder().decode([ManagementDeliveryClient.TranscriptDate].self, from: data)
        XCTAssertEqual(ManagementDeliveryClient.selectedDates(rows, quarters: 4, now: now).map(\.quarter), [2, 1])
        XCTAssertTrue(ManagementDeliveryClient.selectedDates(rows, quarters: 2, now: now).isEmpty)
        XCTAssertNil(ManagementDeliveryRules.isoDate("2025-02-30"))
    }

    func testFinancialAdapterKeepsNullMissingAndFiscalYear() throws {
        let rows: [[String: Any]] = [
            ["symbol": "TEST", "date": "2025-06-28", "filingDate": "2025-07-30", "fiscalYear": "2025", "period": "Q3", "reportedCurrency": "USD",
             "revenue": 10_000, "eps": NSNull(), "netIncome": 0, "grossProfit": true],
            ["symbol": "WRONG", "date": "2025-06-30", "filingDate": "2025-07-30", "fiscalYear": 2025, "period": "Q2", "reportedCurrency": "USD", "revenue": 999],
            ["symbol": "TEST", "date": "2025-06-30", "fiscalYear": 2025, "period": "Q2", "reportedCurrency": "USD", "revenue": 999]
        ]
        let docs = try ManagementDeliveryClient.financialDocuments(JSONSerialization.data(withJSONObject: rows), symbol: "TEST",
            path: "income-statement", sourceURL: URL(string: "https://example.com")!, now: now)
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs[0].period, "Q3")
        XCTAssertEqual(Set(docs[0].facts.map(\.metric)), ["revenue", "netIncome"])
        XCTAssertEqual(docs[0].facts.first(where: { $0.metric == "netIncome" })?.value, 0)
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

    func testSourceURLNeverIncludesAPIKey() {
        let url = ManagementDeliveryClient.sourceURL(path: "earning-call-transcript", parameters: [
            .init(name: "symbol", value: "BRK-B"), .init(name: "apikey", value: "SECRET")])
        XCTAssertFalse(url.absoluteString.contains("SECRET"))
        XCTAssertFalse(url.absoluteString.contains("apikey"))
        XCTAssertTrue(url.absoluteString.contains("BRK-B"))
    }

    func testFourQuarterDownloadWithFinancialSources() async throws {
        let client = ManagementDeliveryClient(fetch: { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            let url = request.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let year = Int(query.first(where: { $0.name == "year" })?.value ?? "2026")!
            let quarter = Int(query.first(where: { $0.name == "quarter" })?.value ?? "1")!
            let rows: [[String: Any]]
            if url.path.hasSuffix("earning-call-transcript-dates") {
                rows = (1...4).map { ["quarter": $0, "fiscalYear": 2025, "date": "2025-\(String(format: "%02d", $0 * 3))-25"] }
            } else if url.path.hasSuffix("earning-call-transcript") {
                rows = [["symbol": "TEST", "year": year, "quarter": quarter, "date": "2025-\(String(format: "%02d", quarter * 3))-25",
                         "content": String(repeating: "Chief Executive Officer: We expect GAAP revenue growth. ", count: 15)]]
            } else {
                let annual = query.contains { $0.name == "period" && $0.value == "annual" }
                rows = [["symbol": "TEST", "date": "2025-12-31", "filingDate": "2026-02-01", "fiscalYear": "2025", "period": annual ? "FY" : "Q4",
                         "reportedCurrency": "USD", "revenue": 12e9, "operatingCashFlow": 1e9,
                         "finalLink": "https://www.sec.gov/Archives/example.htm"]]
            }
            return (try JSONSerialization.data(withJSONObject: rows), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let archive = try await client.download(ticker: "TEST", quarters: 4, key: "TEST-SECRET", now: now, progress: { _ in })
        XCTAssertEqual(archive.documents.filter { $0.kind == .transcript }.count, 4)
        XCTAssertEqual(archive.documents.filter { $0.kind == .financials }.count, 4)
        XCTAssertTrue(archive.documents.filter { $0.kind == .financials }.allSatisfy { $0.rawFinancialJSON != nil && $0.url.host == "www.sec.gov" })
        let encoded = String(data: try JSONEncoder().encode(archive), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("TEST-SECRET"))
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

    func testDownloadRejectsInsufficientCoverageAndNeverPostsDocuments() async throws {
        let client = ManagementDeliveryClient(fetch: { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.host, "financialmodelingprep.com")
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await client.download(ticker: "TEST", quarters: 4, key: "TEST KEY", progress: { _ in })
            XCTFail("Insufficient coverage must fail")
        } catch { XCTAssertTrue(error is ManagementDeliveryError) }
    }

    func testAccessDeniedDoesNotLeakCredentials() async throws {
        let client = ManagementDeliveryClient(fetch: { request in
            (Data("SECRET and raw body".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await client.download(ticker: "TEST", quarters: 4, key: "SECRET", progress: { _ in })
            XCTFail("Access should fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
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
}
