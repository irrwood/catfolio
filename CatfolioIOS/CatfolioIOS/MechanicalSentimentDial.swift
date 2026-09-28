import SwiftUI

/// Full circular dial without ticks or dynamic glass. Static materials are
/// cached independently of the needle's spring and resting motion.
struct MechanicalSentimentDial: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var headerOnly = false
    let score: Int?
    let label: String
    let paused: Bool
    let fraction: (Date) -> Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if headerOnly && !reduceTransparency {
                    artwork("HeaderFace", x: 0, y: 0, width: 454, height: 454)
                } else {
                ZStack(alignment: .topLeading) {
                    artwork("Bezel", x: 0, y: 0, width: 454, height: 454)
                    artwork("Rim", x: 17, y: 17, width: 420, height: 420)
                    artwork("Face", x: 20, y: 20, width: 414, height: 414)
                    artwork("Stroke", x: 20, y: 20, width: 414, height: 414)
                    artwork(headerOnly ? "NewSpectrum" : "Spectrum", x: 34, y: 34, width: 386, height: headerOnly ? 386 : 193)
                    artwork("Center", x: 127, y: 127, width: 200, height: 200)
                }
                .frame(width: 454, height: 454)
                .drawingGroup()
                }
                if score != nil {
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { timeline in
                        ZStack(alignment: .topLeading) {
                            artwork(headerOnly ? "PanelNeedle" : "Needle", x: 0, y: 0, width: 50, height: 240)
                            if !headerOnly {
                                artwork("Tip", x: 22, y: 4, width: 6, height: 28)
                            }
                        }
                        .frame(width: 50, height: 240, alignment: .topLeading)
                        .drawingGroup()
                        .rotationEffect(.degrees((fraction(timeline.date) - 0.5) * 180),
                                        anchor: UnitPoint(x: 0.5, y: 175.0 / 240))
                        .position(x: 227, y: 172)
                    }
                }
                if headerOnly {
                    artwork("GlossSoft", x: 98.48, y: 41.90, width: 260.28, height: 170.13)
                        .blendMode(.softLight)
                    artwork("GlossHard", x: 98.48, y: 41.90, width: 260.28, height: 170.13)
                        .blendMode(.hardLight)
                }
                if !headerOnly {
                artwork("Hub", x: 212, y: 212, width: 30, height: 30)
                artwork("HubLight", x: 212, y: 212, width: 30, height: 30)
                artwork("Reflection", x: 115, y: 20, width: 319.294, height: 288.514)
                    .blendMode(.hardLight)
                }
                if !headerOnly {
                Text(score.map(String.init) ?? "—")
                    .font(.system(size: 52.21, weight: .semibold).width(.condensed))
                    .monospacedDigit()
                    .frame(width: 180, height: 63)
                    .position(x: 227.5, y: 358.5)
                Text(label)
                    .font(.system(size: 20, weight: .semibold).width(.condensed))
                    .frame(width: 180, height: 25)
                    .position(x: 227, y: 398.5)
                Text(L10n.text("极度恐惧"))
                    .font(.system(size: 14, weight: .semibold).width(.condensed))
                    .position(x: 88.5, y: 241)
                Text(L10n.text("极度贪婪"))
                    .font(.system(size: 14, weight: .semibold).width(.condensed))
                    .position(x: 366.5, y: 240)
                }
            }
            .foregroundStyle(.black)
            .frame(width: 454, height: 454)
            // Fade in the same 454pt coordinate space as the artwork, then
            // scale both together. A post-scale mask outlives the image edge.
            .mask {
                if headerOnly {
                    LinearGradient(stops: [.init(color: .white, location: 0.65),
                                           .init(color: .white.opacity(0.55), location: 0.78),
                                           .init(color: .white.opacity(0.12), location: 0.90),
                                           .init(color: .clear, location: 0.97)],
                                   startPoint: .top, endPoint: .bottom)
                } else { Color.white }
            }
            .scaleEffect(geometry.size.width / 454, anchor: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func artwork(_ layer: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Image("SentimentDial" + layer)
            .resizable()
            .frame(width: width, height: height)
            .position(x: x + width / 2, y: y + height / 2)
    }
}
