import SwiftUI

/// The corner option on 收益来源 and 亏损分析: draw every day with that day's
/// own holdings, so a security sold since is in the chart until its sale and
/// out of it from then on (`ActualHoldingHistory`).
struct IncludesSoldMenu: View {
    @Binding var isOn: Bool

    var body: some View {
        Menu {
            Toggle(isOn: $isOn) {
                Text(L10n.text("包含已卖出"))
                Text(L10n.text("按每天真实的持股重算，卖出的股票画到卖出那天为止"))
            }
        } label: {
            Image(systemName: isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(L10n.text("包含已卖出"))
        .accessibilityValue(isOn ? L10n.text("已开启") : L10n.text("已关闭"))
    }
}
