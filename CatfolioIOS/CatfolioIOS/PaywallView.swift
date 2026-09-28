import SwiftUI

/// UI preview only. No StoreKit requests or entitlement changes are made here.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlan: PaywallPlan = .monthly
    @State private var notice: PaywallPreviewNotice?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    plans
                    benefits
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .background(SettingsTemplate.pageBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseFooter }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.text("关闭"))
                    .accessibilityIdentifier("paywall-close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("恢复购买")) { notice = .restore }
                        .appText(.label)
                }
            }
            .alert(item: $notice) { item in
                Alert(title: Text(L10n.text("付费墙预览")),
                      message: Text(item == .restore
                        ? L10n.text("当前是测试页面，尚未连接 App Store，没有恢复或更改任何购买记录。")
                        : L10n.text("已选择\(selectedPlan.title)，\(selectedPlan.priceDescription)。当前仅演示购买流程，不会扣费或更改当前功能。")),
                      dismissButton: .default(Text(L10n.text("好"))))
            }
        }
        .tint(CatfolioTheme.accent)
    }

    private var hero: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(CatfolioTheme.accent)
                .frame(width: 68, height: 68)
                .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 26))
                .accessibilityHidden(true)
            Text("CATFOLIO PRO")
                .font(.caption.weight(.bold))
                .tracking(3)
                .foregroundStyle(SettingsTemplate.secondaryText)
            Text(L10n.text("看清你的每一笔投资"))
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("账户、收益与研究，在一处看得更完整。"))
                .appText(.subheading)
                .foregroundStyle(SettingsTemplate.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var benefits: some View {
        SettingsCard {
            benefit("square.stack.3d.up", L10n.text("账户全景"), L10n.text("汇总多个账户，统一查看资产与现金。"))
            benefit("chart.bar.xaxis", L10n.text("深入理解收益"), L10n.text("追踪收益来源、持仓贡献与历史表现。"))
            benefit("sparkles", L10n.text("AI 辅助研究"), L10n.text("结合持仓与公司信息，梳理投资问题。"))
        }
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        SettingsRowContainer {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).appText(.subheading, weight: .semibold)
                    Text(detail).appText(.label)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("选择你的方案")).appText(.subheading, weight: .semibold)
                Spacer()
                Text("USD").appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
            }
            ForEach(PaywallPlan.allCases) { plan in
                Button { selectedPlan = plan } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedPlan == plan ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selectedPlan == plan ? CatfolioTheme.accent : SettingsTemplate.secondaryText)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plan.title).appText(.subheading, weight: .semibold)
                            Text(plan == .monthly ? L10n.text("按月续订") : L10n.text("一次付费，无需续订"))
                                .appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(plan == .monthly ? "$7.99" : "$100")
                                .font(.title2.weight(.bold)).monospacedDigit()
                            Text(plan == .monthly ? L10n.text("每月") : L10n.text("一次购买"))
                                .appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(selectedPlan == plan ? CatfolioTheme.accent : SettingsTemplate.separator,
                                          lineWidth: selectedPlan == plan ? 2 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPlan == plan ? .isSelected : [])
                .accessibilityIdentifier("paywall-plan-\(plan.rawValue)")
            }
            Text(L10n.text("行情与 AI 仍使用你配置的服务商。"))
                .appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            Text(selectedPlan == .monthly
                 ? L10n.text("每月 $7.99，自动续订，可在 App Store 管理或取消。")
                 : L10n.text("一次支付 $100，终身使用，无需续订。"))
                .appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            GlassPrimaryButton(title: selectedPlan == .monthly ? L10n.text("订阅 · $7.99/月") : L10n.text("解锁终身版 · $100"), systemImage: "arrow.right") {
                notice = .purchase
            }
            .accessibilityIdentifier("paywall-continue")
            Text(L10n.text("界面预览，不会扣费。套餐与权益仅作展示。"))
                .appText(.label)
                .foregroundStyle(SettingsTemplate.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(SettingsTemplate.pageBackground)
    }
}

private enum PaywallPreviewNotice: String, Identifiable {
    case purchase, restore
    var id: String { rawValue }
}


enum PaywallPlan: String, CaseIterable, Identifiable {
    case monthly, lifetime
    var id: String { rawValue }
    var title: String { self == .monthly ? L10n.text("月度订阅") : L10n.text("终身版") }
    var priceDescription: String {
        self == .monthly ? L10n.text("每月 7.99 美元") : L10n.text("一次支付 100 美元")
    }
}
