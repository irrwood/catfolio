import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class ScreenshotImportViewTests: XCTestCase {
    func testRealOCRReadsLightAndDarkScreenshotTables() async throws {
        for dark in [false, true] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1400, height: 600)).image { context in
                (dark ? UIColor.black : UIColor.white).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1400, height: 600))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 32),
                    .foregroundColor: dark ? UIColor.white : UIColor.black
                ]
                let xs: [CGFloat] = [40, 330, 570, 870, 1130]
                for (row, texts) in [
                    ["Ticker", "Shares", "Avg cost", "Price", "Currency"],
                    ["AAPL", "12.5", "150.25", "180.50", "USD"],
                    ["MSFT", "4", "300", "350", "USD"]
                ].enumerated() {
                    for (x, text) in zip(xs, texts) {
                        (text as NSString).draw(at: CGPoint(x: x, y: CGFloat(100 + row * 100)),
                                                withAttributes: attributes)
                    }
                }
            }
            let boxes = try await ScreenshotTextRecognizer.recognize(XCTUnwrap(image.pngData()))
            let drafts = ScreenshotImportParser.parse(boxes)
            XCTAssertEqual(drafts.map(\.ticker), ["AAPL", "MSFT"], "\(boxes)")
            XCTAssertEqual(drafts.first?.shares, "12.5")
            XCTAssertEqual(drafts.first?.averageCost, "150.25")
            XCTAssertEqual(drafts.first?.price, "180.50")
            XCTAssertEqual(drafts.first?.currency, "USD")
            XCTAssertNil(drafts.first?.problem)
            let attachment = XCTAttachment(image: image)
            attachment.name = "screenshot-ocr-\(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testInvalidImageFailsWithoutDrafts() async {
        do {
            _ = try await ScreenshotTextRecognizer.recognize(Data("not an image".utf8))
            XCTFail("Invalid image must be rejected")
        } catch {}
    }

    func testReviewFieldsStayLabelledAndEditableAtLargeTextSizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let value = DraftBox()
        var removed = false
        let host = UIHostingController(rootView: ScreenshotHoldingEditor(
            draft: Binding(get: { value.draft }, set: { value.draft = $0 }), onRemove: { removed = true })
            .environment(\.dynamicTypeSize, .accessibility1)
            .frame(width: 320))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 3000))
        window.frame = CGRect(origin: .zero, size: CGSize(width: 320, height: ceil(size.height)))
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(size.width, 320, accuracy: 1)
        let fields = descendants(host.view, as: UITextField.self)
        XCTAssertEqual(fields.count, 5)
        let shares = try XCTUnwrap(fields.first { $0.text == "10" })
        shares.text = "12.5"
        shares.sendActions(for: .editingChanged)
        XCTAssertEqual(value.draft.shares, "12.5")
        XCTAssertFalse(removed)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "screenshot-review-large-text"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-screenshot-review.png"))
    }

    private func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }

    private final class DraftBox {
        var draft = ScreenshotHoldingDraft(ticker: "AAPL", shares: "10", averageCost: "150",
                                          price: "180", currency: "USD")
    }
}
