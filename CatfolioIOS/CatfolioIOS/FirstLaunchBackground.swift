import SwiftUI
import UIKit

/// One canvas behind the whole navigation stack; only foreground pages move.
struct FirstLaunchBackground: View {
    enum Stage: Equatable {
        case welcome, selection, service(LocalServiceProvider), broker(AddAccountProvider)
    }
    let stage: Stage

    var body: some View {
        Group {
            if case .broker(let provider) = stage {
                AccountConnectionBackground(theme: provider.flowTheme, isPreparation: true)
            } else {
                LinearGradient(stops: [
                    .init(color: colors.0, location: 0),
                    .init(color: colors.1, location: 0.65),
                    .init(color: colors.2, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var colors: (Color, Color, Color) {
        switch stage {
        case .welcome:
            blueColors
        case .selection:
            violetColors
        case .service(let provider):
            switch provider {
            case .massive, .fmp, .finnhub:
                blueColors
            default:
                violetColors
            }
        case .broker:
            blueColors
        }
    }

    private var blueColors: (Color, Color, Color) {
        (CatfolioPalette.FirstLaunch.top, CatfolioPalette.FirstLaunch.middle, CatfolioPalette.FirstLaunch.bottom)
    }

    private var violetColors: (Color, Color, Color) {
        (CatfolioPalette.FirstLaunch.violetTop, CatfolioPalette.FirstLaunch.violetMiddle, CatfolioPalette.FirstLaunch.violetBottom)
    }
}

/// Clear only the hosting ancestors inside this onboarding navigation stack.
/// No global appearance changes and no replacement of the system's delegate.
struct FirstLaunchNavigationBackdropAnchor: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.prepareBackdrop() }

    final class Controller: UIViewController {
        override func loadView() {
            view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            prepareBackdrop()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            prepareBackdrop()
        }
        func prepareBackdrop() {
            var ancestor = parent
            while let current = ancestor {
                current.view.backgroundColor = .clear
                if current is UINavigationController { break }
                ancestor = current.parent
            }
        }
    }
}
