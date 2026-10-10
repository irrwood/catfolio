import SwiftUI
import Charts
import CryptoKit
import Observation

/// The scan's thresholds, in 编辑规则. A holding is listed when it crosses
/// any one of them and marked 高关注 when it crosses several.
struct AttentionSignalRulesSections: View {
    private typealias Rules = AttentionSignalRules
    @AppStorage(Rules.returnWindowKey) private var returnWindow = Rules.defaults.returnWindowDays
    @AppStorage(Rules.returnThresholdKey) private var returnThreshold = Rules.defaults.returnThreshold
    @AppStorage(Rules.volumeMultipleKey) private var volumeMultiple = Rules.defaults.volumeMultiple
    @AppStorage(Rules.volumeBaselineKey) private var volumeBaseline = Rules.defaults.volumeBaselineDays
    @AppStorage(Rules.nearExtremeKey) private var nearExtreme = Rules.defaults.nearExtremePercent
    @AppStorage(Rules.todayMoveKey) private var todayMove = Rules.defaults.todayMoveThreshold
    @AppStorage(Rules.movingAverageKey) private var movingAverage = Rules.defaults.movingAverageDays
    @AppStorage(Rules.contributionShareKey) private var contributionShare = Rules.defaults.contributionShare
    @AppStorage(Rules.highAttentionKey) private var highAttention = Rules.defaults.highAttentionSignals
    @State private var confirmsReset = false

    private var isDefault: Bool {
        Rules.current == Rules.defaults
    }

    var body: some View {
        Section {
            Picker(L10n.text("涨跌幅周期"), selection: $returnWindow) {
                ForEach(Rules.returnWindowChoices, id: \.self) { Text("\($0)D").tag($0) }
            }
            stepper(L10n.text("涨跌幅阈值"), value: $returnThreshold, in: 3...40, step: 1, text: "±\(Int(returnThreshold))%")
            Picker(L10n.text("均线"), selection: $movingAverage) {
                ForEach(Rules.movingAverageChoices, id: \.self) { Text("MA\($0)").tag($0) }
            }
            stepper(L10n.text("接近 52 周高低点"), value: $nearExtreme, in: 0.5...10, step: 0.5,
                    text: L10n.text("\(Self.number(nearExtreme))% 以内"))
        } header: {
            Text(L10n.text("价格信号"))
        } footer: {
            Text(L10n.text("涨跌幅是现价相对 N 天前收盘的变化；均线信号在现价上穿或下穿均线的那天出现。"))
        }

        Section {
            stepper(L10n.text("放量倍数"), value: $volumeMultiple, in: 1.5...5, step: 0.5, text: "\(Self.number(volumeMultiple))×")
            Picker(L10n.text("放量基准"), selection: $volumeBaseline) {
                ForEach(Rules.volumeBaselineChoices, id: \.self) { Text(L10n.text("\($0) 日均量")).tag($0) }
            }
            stepper(L10n.text("今日异动"), value: $todayMove, in: 1...15, step: 0.5, text: "±\(Self.number(todayMove))%")
            stepper(L10n.text("占今日组合波动"), value: $contributionShare, in: 20...80, step: 5, text: "\(Int(contributionShare))%")
        } header: {
            Text(L10n.text("成交与异动"))
        }

        Section {
            Stepper(value: $highAttention, in: 1...4) {
                row(L10n.text("高关注至少"), L10n.text("\(highAttention) 个信号"))
            }
            Button(L10n.text("恢复默认参数"), role: .destructive) { confirmsReset = true }
                .disabled(isDefault)
                .confirmationDialog(L10n.text("恢复默认参数？"), isPresented: $confirmsReset, titleVisibility: .visible) {
                    Button(L10n.text("恢复默认"), role: .destructive) { reset() }
                    Button(L10n.text("取消"), role: .cancel) {}
                } message: {
                    Text(L10n.text("60D ±10%、MA200、52 周高低点 3% 以内、2× 30 日均量、今日 ±5%、占组合波动 40%、2 个信号为高关注。"))
                }
        } footer: {
            Text(L10n.text("满足任一信号即列入今天值得关注，满足设定个数为高关注。阈值调低会列出更多持仓。下次刷新分析时生效。"))
        }
    }

    private func stepper(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                         step: Double, text: String) -> some View {
        Stepper(value: value, in: range, step: step) { row(title, text) }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// Writing the defaults back, not only removing the keys, so every
    /// control on screen updates at once.
    private func reset() {
        let base = Rules.defaults
        returnWindow = base.returnWindowDays
        returnThreshold = base.returnThreshold
        volumeMultiple = base.volumeMultiple
        volumeBaseline = base.volumeBaselineDays
        nearExtreme = base.nearExtremePercent
        todayMove = base.todayMoveThreshold
        movingAverage = base.movingAverageDays
        contributionShare = base.contributionShare
        highAttention = base.highAttentionSignals
        Rules.reset()
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
