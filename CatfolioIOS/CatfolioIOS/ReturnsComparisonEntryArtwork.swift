import SwiftUI

/// The two comparison entry surfaces from Figma 487:5331 and 641:25494.
struct ReturnsComparisonEntryArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let isCycle: Bool
    var returnPercent: Double? = nil
    private var isDay: Bool { colorScheme == .light }
    private var amountInk: Color { isCycle ? .white : (isDay ? ReturnsEntryStyle.returnDayInk : .black) }
    private var titleInk: Color { isDay && !isCycle ? ReturnsEntryStyle.returnDayInk : .white }
    private var prefix: String { isCycle ? "EntryCycle" : "EntryReturn" }
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(prefix + "Icon")
                    .renderingMode(.template)
                    .foregroundStyle(titleInk)
                Spacer()
                Image(isCycle ? "EntryChevron" : "EntryReturnChevron").renderingMode(.original)
            }
            .frame(height: 24)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(isCycle ? "performance.card.cycle.title" : "performance.card.return.title"))
                    .font(Typography.text(size: 14, weight: .bold))
                    .tracking(0.56)
                    .textCase(.uppercase)
                    .foregroundStyle(titleInk.opacity(0.4))
                    .blendMode(isDay && !isCycle ? .darken : .plusLighter)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    FinancialText(returnPercent.map { DisplayFormat.percent($0, signed: true) } ?? "—", isDirectional: isDay, signFollowsValue: true)
                        .font(Typography.number(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("ARR")
                        .font(Typography.number(size: 14, weight: .semibold))
                        .fixedSize()
                }
                .foregroundStyle(amountInk)
            }
        }
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 173)
        .background {
            GeometryReader { proxy in
                illustration
                    .frame(width: 173, height: 173)
                    .scaleEffect(x: proxy.size.width / 173, y: 1, anchor: .topLeading)
            }
        }
        .clipShape(shape)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(L10n.text(isCycle ? "当年年化收益率" : "全部投资期间年化收益率") + ": " +
            (returnPercent.map { DisplayFormat.percent($0, signed: true) } ?? "—"))
    }

    private var illustration: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            (isCycle ? ReturnsEntryStyle.cycleFill : ReturnsEntryStyle.returnFill)
                .opacity(isDay ? 1 : 0.6)
            if isCycle || isDay { stripes }
            asset("Back", width: 188, height: 156.955, x: -8, y: 35)
            if !isCycle { glow }
            asset("Middle", width: 188.5, height: 141.028, x: -8, y: 50.952)
            asset("Front", width: 188.5, height: isCycle ? 112.456 : 142.214,
                  x: -8, y: isCycle ? 100.535 : 70.782)
        }
        .frame(width: 173, height: 173, alignment: .topLeading)
        .drawingGroup()
        .visualEffect { content, proxy in
            content.layerEffect(Shader(function: ShaderFunction(library: .default, name: "returnsProgressiveBlur"), arguments: [
                .float2(proxy.size), .float2(0.364, 0.587), .float2(0.147, 1), .float(18.1)
            ]), maxSampleOffset: CGSize(width: 18.1, height: 18.1))
        }
        .overlay(alignment: .topLeading) { if isCycle { glow } }
        .overlay { if !isCycle && !isDay { stripes } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var glow: some View {
        asset("Glow", width: 355.6, height: 279.6, x: -163.8, y: 28.2)
            // Asset-catalog SVG rendering omits the exported SVG blur filter.
            .blur(radius: 32.9)
    }

    private func asset(_ suffix: String, width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Image(prefix + suffix)
            .renderingMode(.original)
            .frame(width: width, height: height).offset(x: x, y: y)
            // Exported blur padding must not enlarge the stack's gradients
            // or stripe bands. Keep the SVG intact on the card's own canvas.
            .frame(width: 173, height: 173, alignment: .topLeading)
    }

    @ViewBuilder private var stripes: some View {
        if isCycle {
            HStack(spacing: 0) {
                ForEach(0..<5) { index in
                    LinearGradient(colors: index.isMultiple(of: 2) ? [.white, .clear] : [.clear, .white],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .blendMode(.overlay)
        } else {
            VStack(spacing: 0) {
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
            }
            .blendMode(.overlay)
        }
    }

}

/// Annualized money-weighted investment returns for the two entry scopes.
enum ReturnsEntrySummary {
    static func allTimePercent(_ comparison: ComparisonResponse?) -> Double? {
        comparison?.mwrLedger?.annualizedReturn().map { $0 * 100 }
    }

    static func yearToDatePercent(_ comparison: ComparisonResponse?, now: Date = Date()) -> Double? {
        guard let ledger = comparison?.mwrLedger,
              let latestKey = ledger.dates.last,
              let latest = DayDateCodec.date(from: latestKey) else { return nil }
        let calendar = ChartTimeRange.financeCalendar
        guard calendar.isDate(latest, equalTo: now, toGranularity: .year),
              let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now)),
              let start = ledger.dates.firstIndex(where: {
                  DayDateCodec.date(from: $0).map { $0 >= yearStart } ?? false
              }), let result = ledger.annualizedReturn(startIndex: start) else { return nil }
        return result * 100
    }
}
