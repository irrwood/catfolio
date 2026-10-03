import SwiftUI

/// The security page's entry to the dividend income calculator. Shown only
/// once the listing is known to have paid a dividend in the past year; until
/// then it takes no room, so the page does not open on an empty row.
struct DividendIncomeCalculatorCard: View {
    let ticker: String
    let heldShares: Double
    @State private var income: DividendIncome?
    @State private var showsCalculator = false

    var body: some View {
        // A zero-height anchor, not an empty group: the load task must run
        // while the card is still hidden.
        ZStack {
            if let income {
                Button { showsCalculator = true } label: {
                    HoldingDetailActionCardLabel(title: L10n.text("股息收入计算器"),
                        subtitle: L10n.text("按股数估算股息收入"))
                }
                .buttonStyle(.plain)
                .padding(.top, HoldingDetailCardStyle.spacing)
                .accessibilityIdentifier("holding.dividend-calculator")
                .appSheet(isPresented: $showsCalculator) {
                    DividendIncomeCalculatorView(income: income, heldShares: heldShares)
                }
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task(id: ticker) {
            income = (try? await LocalMarketDataClient().dividendPayments(symbol: ticker))
                .flatMap { DividendIncome(payments: $0) }
        }
    }
}

struct DividendIncomeCalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let income: DividendIncome
    let heldShares: Double
    private let steps: [Double]
    @State private var shares: Double
    @State private var draft: String
    @State private var stepIndex: Int
    @FocusState private var editing: Bool

    init(income: DividendIncome, heldShares: Double) {
        self.income = income
        self.heldShares = heldShares
        let steps = DividendIncome.shareSteps(including: heldShares)
        let start = heldShares > 0 ? heldShares : 100
        self.steps = steps
        _shares = State(initialValue: start)
        _draft = State(initialValue: DisplayFormat.shares(start))
        _stepIndex = State(initialValue: DividendIncome.nearestStep(to: start, in: steps))
    }

    private var canReset: Bool { heldShares > 0 && abs(shares - heldShares) > 0.000_1 }

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 24, topInset: SettingsTemplate.sectionSpacing) {
                SettingsCard {
                    resultRow(L10n.text("下一笔付款"), income.nextPerShare)
                    resultRow(L10n.text("年收入（TTM）"), income.trailingPerShare)
                    resultRow(L10n.text("年收入（FWD）"), income.forwardPerShare)
                }
                SettingsCard { sharesEditor }
            }
            .navigationTitle(L10n.text("股息收入计算器"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { AppModalDoneButton { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.text("完成")) { editing = false }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func resultRow(_ title: String, _ perShare: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appText(.footnote, weight: .medium)
                .foregroundStyle(SettingsTemplate.secondaryText)
            Text(DisplayFormat.money(perShare * shares, currency: income.currency, fractionDigits: 2))
                .appNumber(.title)
                .foregroundStyle(CatfolioTheme.primaryText)
                .contentTransition(.numericText(value: perShare * shares))
                .animation(.snappy(duration: 0.25), value: shares)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
        .padding(.vertical, SettingsTemplate.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private var sharesEditor: some View {
        VStack(spacing: 14) {
            HStack {
                Text(L10n.text("股数"))
                    .appText(.footnote, weight: .medium)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                Spacer()
                Button(action: reset) {
                    Label(L10n.text("复位"), systemImage: "arrow.counterclockwise")
                        .appText(.footnote, weight: .medium)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.primary)
                .controlSize(.small)
                .opacity(canReset ? 1 : 0)
                .disabled(!canReset)
                .animation(.easeOut(duration: 0.2), value: canReset)
                .accessibilityIdentifier("dividend-calculator.reset")
            }
            TextField("0", text: $draft)
                .keyboardType(.decimalPad)
                .focused($editing)
                .multilineTextAlignment(.center)
                .appNumber(.display)
                .foregroundStyle(CatfolioTheme.primaryText)
                .accessibilityLabel(L10n.text("股数"))
                .accessibilityIdentifier("dividend-calculator.shares")
                .onChange(of: draft) { _, text in typed(text) }
                .onChange(of: editing) { _, isEditing in
                    if !isEditing { draft = DisplayFormat.shares(shares) }
                }
            SectorRotationTimeline(index: stepIndex, dates: steps.map(DisplayFormat.shares),
                centersSelection: true, coast: (60, 0.85), accessibilityName: L10n.text("股数"),
                onInteraction: { editing = false }) { value in
                stepIndex = value
                shares = steps[value]
                draft = DisplayFormat.shares(shares)
            }
            .frame(height: 44)
        }
        .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
        .padding(.vertical, SettingsTemplate.rowVerticalPadding)
    }

    private func typed(_ text: String) {
        // Only while the keyboard is up: the slider writes the draft too.
        guard editing else { return }
        let normalized = text.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
        guard let value = Double(normalized), value.isFinite, value >= 0 else {
            if normalized.isEmpty { shares = 0; stepIndex = 0 }
            return
        }
        shares = value
        stepIndex = DividendIncome.nearestStep(to: value, in: steps)
    }

    private func reset() {
        editing = false
        if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        shares = heldShares
        draft = DisplayFormat.shares(heldShares)
        stepIndex = DividendIncome.nearestStep(to: heldShares, in: steps)
    }
}
