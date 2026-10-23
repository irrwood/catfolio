import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountCredentialVisibilityTests: XCTestCase {
    func testVisibilityChangesArtworkAndPreservesOpticalTrailingInset() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let draft = Draft()
        let host = UIHostingController(rootView: input(draft, dark: false))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(250))
        let field = try XCTUnwrap(findField(window))
        for dark in [false, true] {
            host.rootView = input(draft, dark: dark)
            var masks: [Set<Int>] = []
            for revealed in [false, true, false] {
                draft.revealed = revealed
                // Sample before an inherited one-second animation could finish.
                try await Task.sleep(for: .milliseconds(50))
                window.layoutIfNeeded()
                XCTAssertTrue(findField(window) === field)
                XCTAssertEqual(field.isSecureTextEntry, !revealed)
                XCTAssertEqual(field.text, "demo-key-123")
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let mask = try eyePixels(image)
                XCTAssertGreaterThan(mask.count, 30, "The eye must remain visible in both color schemes")
                let bitmap = try XCTUnwrap(image.cgImage)
                let rightEdge = CGFloat(try XCTUnwrap(mask.map { $0 % bitmap.width }.max()) + 1) / image.scale
                let rowRight = field.convert(field.bounds, to: window).minX - 20 + 370
                XCTAssertEqual(rowRight - rightEdge, 20, accuracy: 2,
                               "Measure the visible artwork edge, including its internal transparent margin")
                masks.append(mask)
                try image.pngData()?.write(to: URL(fileURLWithPath:
                    "/tmp/catfolio-account-eye-\(dark ? "dark" : "light")-\(revealed ? "open" : "closed").png"))
            }
            XCTAssertNotEqual(masks[0], masks[1], "Revealing a credential must switch from closed to open eyes")
            XCTAssertEqual(masks[0], masks[2], "Hiding it again must restore the closed-eye artwork and position")
        }
    }

    private func input(_ draft: Draft, dark: Bool) -> some View {
        ServiceAPIKeyInput(placeholder: "API Key",
            text: Binding(get: { draft.text }, set: { draft.text = $0 }),
            revealsKey: Binding(get: { draft.revealed }, set: { draft.revealed = $0 }),
            isAccountCredential: true)
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .padding(.vertical, 16)
            .frame(width: 370, height: 64)
            .background(CatfolioPalette.accountCredentialBackground, in: RoundedRectangle(cornerRadius: 24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dark ? Color.black : Color.white)
            .accountFlowBrand(.trading212)
            .preferredColorScheme(dark ? .dark : .light)
            .animation(.linear(duration: 1), value: draft.revealed)
    }

    private func eyePixels(_ image: UIImage) throws -> Set<Int> {
        let bitmap = try XCTUnwrap(image.cgImage)
        let width = bitmap.width
        let height = bitmap.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Set((0..<(width * height)).filter { index in
            let offset = index * 4
            return index % width > width / 2 && pixels[offset] < 80
                && pixels[offset + 1] > 120 && pixels[offset + 2] > 200
        })
    }

    private func findField(_ view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        return view.subviews.lazy.compactMap { self.findField($0) }.first
    }

    @Observable final class Draft {
        var text = "demo-key-123"
        var revealed = false
    }
}
