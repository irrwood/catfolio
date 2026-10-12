import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AIEmptyStateLayoutTests: XCTestCase {
    func testPresetsStartBroadAndKeepEveryResearchToolOnce() {
        XCTAssertEqual(AIQuestionPreset.displayOrder,
                       [.market, .overview, .news, .earnings, .valuation, .trend, .options])
        XCTAssertEqual(Set(AIQuestionPreset.displayOrder), Set(AIQuestionPreset.allCases))
        XCTAssertEqual(AIQuestionPreset.displayOrder.count, AIQuestionPreset.allCases.count)
    }

    func testCardsStayInOneColumnAndGrowForAccessibleText() throws {
        let saved = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(saved, forKey: AppLanguage.preferenceKey) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            for width in [288.0, 370.0] {
                var normalHeight = 0.0
                for type in [DynamicTypeSize.large, .accessibility3] {
                    let cardsHeight = AIQuestionPreset.displayOrder.reduce(0.0) { height, preset in
                        height + measured(AIQuestionPresetCard(preset: preset), width: width, type: type).height
                    }
                    let page = measured(AIQuestionPresets(onSelect: { _ in }), width: width, type: type)
                    XCTAssertEqual(page.width, width, accuracy: 1)
                    XCTAssertGreaterThan(page.height, cardsHeight,
                                         "All seven cards must occupy separate rows, plus the introduction")
                    if type == .large {
                        normalHeight = page.height
                        XCTAssertLessThan(page.height, 750, "The default cards should remain compact")
                    } else {
                        XCTAssertGreaterThan(page.height, normalHeight,
                                             "Large text must grow the rows instead of clipping")
                    }
                }
            }
        }
    }

    func testSuggestionSurfacesRemainWhiteAndTranslucentInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            for color in [CatfolioTheme.assistantSuggestionFill(for: scheme),
                          CatfolioTheme.assistantSuggestionBorder(for: scheme)] {
                let resolved = color.resolve(in: environment)
                XCTAssertEqual(resolved.red, 1)
                XCTAssertEqual(resolved.green, 1)
                XCTAssertEqual(resolved.blue, 1)
                XCTAssertGreaterThan(resolved.opacity, 0)
                XCTAssertLessThan(resolved.opacity, 1)
            }
        }
    }

    func testTopBackdropFadesCompletelyAndDoesNotInterceptTouches() throws {
        let view = AIStatusBackdropBlur.BlurView()
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 146)
        view.layoutIfNeeded()
        XCTAssertFalse(view.isUserInteractionEnabled)
        let mask = try XCTUnwrap(view.mask)
        XCTAssertEqual(mask.frame, view.bounds)
        let gradient = try XCTUnwrap(mask.layer.sublayers?.first as? CAGradientLayer)
        let colors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertEqual(colors.first?.alpha, 1)
        XCTAssertEqual(colors.last?.alpha, 0)
        for (first, second) in zip(colors, colors.dropFirst()) {
            XCTAssertGreaterThanOrEqual(first.alpha, second.alpha)
        }
        view.frame.size = CGSize(width: 320, height: 110)
        view.layoutIfNeeded()
        XCTAssertEqual(mask.frame, view.bounds)
        XCTAssertEqual(gradient.frame, mask.bounds)
    }

    func testOpenConversationCanScrollUnderHeaderWhileHistoryCardClipsItsCorners() {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 600)
        let open = AIConversationCardClip(radius: 0, topOverflow: 160).path(in: bounds)
        XCTAssertTrue(open.contains(CGPoint(x: 200, y: -100)))
        let lifted = AIConversationCardClip(radius: 40, topOverflow: 0).path(in: bounds)
        XCTAssertFalse(lifted.contains(CGPoint(x: 200, y: -100)))
        XCTAssertFalse(lifted.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(lifted.contains(CGPoint(x: 200, y: 10)))
    }

    private func measured<Content: View>(_ content: Content, width: CGFloat, type: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: content.environment(\.dynamicTypeSize, type))
        return host.sizeThatFits(in: CGSize(width: width, height: 5_000))
    }
}
