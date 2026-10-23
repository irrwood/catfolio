import SwiftUI
import UIKit
import Vision
import XCTest
@testable import CatfolioIOS

@MainActor
final class CashFlowStatementViewTests: XCTestCase {
    func testHierarchyKeepsCashFlowSignsMissingDisclosureAndFCFDefinitions() throws {
        let report = fixture()
        let presentation = CashFlowStatementPresentation(period: report)
        let rows = presentation.sections.flatMap(\.rows)
        XCTAssertEqual(presentation.sections.map(\.id), ["operating", "investing", "financing", "cash", "freeCashFlow"])
        XCTAssertGreaterThan(rows.count, 25)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == "capitalExpenditure" }?.value), -18_997_000_000)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == "baseFreeCashFlow" }?.value), 13_229_000_000)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == "leaseAdjustedFreeCashFlow" }?.value), 12_386_000_000)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == "sourceFreeCashFlow" }?.value), 12_386_000_000)
        XCTAssertNil(rows.first { $0.id == "debtIssued" }?.value)
        XCTAssertEqual(presentation.amount(nil), "—")
        XCTAssertEqual(presentation.amount(.nan), "—")
        XCTAssertTrue(presentation.amount(report.operatingCashFlow).hasPrefix("+"))
        XCTAssertTrue(presentation.amount(report.investingCashFlow).hasPrefix("-"))
        XCTAssertFalse(presentation.amount(39_100_000_000, signed: false).hasPrefix("+"))
        XCTAssertEqual(rows.first { $0.id == "commonStockRepurchased" }?.value, 0,
                       "A disclosed zero must remain distinct from an unavailable detail")
    }

    func testMissingLeasePrincipalNeverBecomesAnAdjustedFCF() {
        var report = fixture()
        report.details?.amounts.removeValue(forKey: .financeLeasePrincipalPayments)
        report.details?.sourceFreeCashFlow = nil
        let rows = CashFlowStatementPresentation(period: report).sections.flatMap(\.rows)
        XCTAssertNil(rows.first { $0.id == "leaseAdjustedFreeCashFlow" }?.value)
        XCTAssertFalse(rows.contains { $0.id == "sourceFreeCashFlow" })
        XCTAssertNotNil(rows.first { $0.id == "baseFreeCashFlow" }?.value)
    }

    func testPartialDisclosedSubtotalsAreQualifiedInTheVisibleLabel() throws {
        var report = fixture()
        report.details?.partialItems = [.changeInWorkingCapital]
        ContentLanguage.$requested.withValue("en") {
            let rows = CashFlowStatementPresentation(period: report).sections.flatMap(\.rows)
            XCTAssertTrue(rows.first { $0.id == "changeInWorkingCapital" }?.title.contains("disclosed items") == true)
            XCTAssertFalse(rows.first { $0.id == "netIncome" }?.title.contains("disclosed items") == true)
        }
    }

    func testLatestActualQuarterWinsAndAnnualIsOnlyTheFallback() {
        let latest = fixture(end: "2026-09-30", fiscalPeriod: "Q3")
        let first = fixture(end: "2026-03-31", fiscalPeriod: "Q1")
        let annual = fixture(end: "2025-12-31", fiscalPeriod: "FY", kind: .annual)
        let unsorted = [first, annual, latest]
        XCTAssertEqual(CashFlowPeriodSelection.preferredKind(in: unsorted), .quarterly)
        XCTAssertEqual(CashFlowPeriodSelection.periods(in: unsorted, kind: .quarterly).map(\.periodEnd),
                       ["2026-09-30", "2026-03-31"])
        XCTAssertEqual(CashFlowPeriodSelection.preferredKind(in: [annual]), .annual)
        XCTAssertTrue(CashFlowPeriodSelection.periods(in: [annual], kind: .quarterly).isEmpty)
    }

    func testHierarchyRendersInBothLanguagesSchemesAndAccessibilitySizes() throws {
        let directory = URL(fileURLWithPath: "/tmp/catfolio-cash-flow", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans"] {
            for scheme in [ColorScheme.light, .dark] {
                for large in [false, true] {
                    try ContentLanguage.$requested.withValue(language) {
                        let width: CGFloat = large ? 280 : 362
                        let image = try render(VStack(alignment: .leading, spacing: 24) {
                            CashFlowDiagram(period: fixture())
                            CashFlowStatementRows(period: fixture())
                        }.padding(20).frame(width: width),
                           language: language, scheme: scheme,
                           dynamicTypeSize: large ? .accessibility2 : .large)
                        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
                        XCTAssertGreaterThan(image.size.height, large ? 2_500 : 1_500)
                        let name = "\(language)-\(scheme == .dark ? "dark" : "light")-\(large ? "accessibility" : "regular")"
                        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
                        let attachment = XCTAttachment(image: image)
                        attachment.name = name
                        attachment.lifetime = .keepAlways
                        add(attachment)
                        if language == "en", scheme == .light {
                            let text = try recognizedText(in: image)
                            for title in ["Operating cash flow", "Investing cash flow", "Financing cash flow",
                                          "Opening cash", "Closing cash", "Free cash flow", "Finance lease-adjusted free cash flow"] {
                                let normalizedText = text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                                let normalizedTitle = title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                                XCTAssertTrue(String(String.UnicodeScalarView(normalizedText)).contains(String(String.UnicodeScalarView(normalizedTitle))),
                                              "The full label must remain readable at \(name): \(title)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func fixture(end: String = "2026-03-31", fiscalPeriod: String = "Q1",
                         kind: FinancialPeriodKind = .quarterly) -> CashFlowStatementPeriod {
        .init(periodEnd: end, filedDate: "2026-04-30", fiscalYear: 2026, fiscalPeriod: fiscalPeriod,
              kind: kind, currency: "USD", operatingCashFlow: 32_226_000_000,
              capitalExpenditure: 18_997_000_000, freeCashFlow: 13_229_000_000,
              investingCashFlow: -33_678_000_000, financingCashFlow: -6_553_000_000,
              details: .init(amounts: [
                .netIncome: 26_773_000_000, .depreciationAndAmortization: 5_999_000_000,
                .deferredIncomeTaxes: 123_000_000, .stockBasedCompensation: 6_032_000_000,
                .changeInWorkingCapital: -7_759_000_000, .otherNonCashItems: 1_058_000_000,
                .acquisitions: -372_000_000, .investmentPurchases: -33_522_000_000,
                .investmentSalesAndMaturities: 19_176_000_000, .otherInvestingActivities: 37_000_000,
                .dividendsPaid: -1_346_000_000, .commonStockRepurchased: 0, .commonStockIssued: 0,
                .financeLeasePrincipalPayments: -843_000_000, .otherFinancingActivities: -4_364_000_000,
                .effectOfExchangeRates: 7_000_000, .changeInCash: -7_998_000_000,
                .cashAtBeginningOfPeriod: 39_100_000_000, .cashAtEndOfPeriod: 31_102_000_000,
              ], cashIncludesRestrictedCash: true, sourceFreeCashFlow: 12_386_000_000))
    }

    private func render<V: View>(_ view: V, language: String = "en", scheme: ColorScheme = .light,
                                 dynamicTypeSize: DynamicTypeSize = .large) throws -> UIImage {
        let renderer = ImageRenderer(content: view.fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, dynamicTypeSize))
        // A full, scrolling statement at accessibility sizes can exceed the
        // simulator's maximum backing texture height at Retina scale.
        renderer.scale = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return try XCTUnwrap(renderer.uiImage)
    }

    private func recognizedText(in image: UIImage) throws -> String {
        let source = try XCTUnwrap(image.cgImage)
        // Vision downsamples very tall documents. Read overlapping viewport
        // tiles so accessibility text is checked at its actual rendered size.
        let tileHeight = min(source.height, Int(600 * image.scale))
        let step = max(1, tileHeight - Int(120 * image.scale))
        var text: [String] = []
        for top in stride(from: 0, to: source.height, by: step) {
            let tile = try XCTUnwrap(source.cropping(to: CGRect(
                x: 0, y: top, width: source.width, height: min(tileHeight, source.height - top))))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: tile).perform([request])
            text.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
        }
        return text.joined(separator: " ")
    }

}
