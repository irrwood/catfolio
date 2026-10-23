import SwiftUI

/// UI preview only. No StoreKit requests or entitlement changes are made here.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPlan: PaywallPlan = .monthly
    @State private var notice: PaywallPreviewNotice?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hero
                        benefits.padding(.top, 26)
                        Spacer(minLength: 28)
                        plans
                    }
                    .frame(maxWidth: 520)
                    .frame(minHeight: max(0, geometry.size.height - 28), alignment: .top)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("paywall-content")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseFooter }
            .background {
                LinearGradient(stops: [
                    .init(color: CatfolioPalette.Paywall.top, location: 0),
                    .init(color: CatfolioPalette.Paywall.middle, location: 0.52),
                    .init(color: CatfolioPalette.Paywall.glow, location: 0.82),
                    .init(color: CatfolioPalette.Paywall.bottom, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("关闭弹窗"), systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("paywall-close")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Text("CATFOLIO").appCaps(.label).tracking(2)
                        Text("PRO")
                            .appText(.micro, weight: .bold)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("恢复")) { notice = .restore }
                        .appText(.label)
                        .accessibilityLabel(L10n.text("恢复购买"))
                        .accessibilityIdentifier("paywall-restore")
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
        .tint(.white)
        .preferredColorScheme(.dark)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("你的投资，\n一目了然。"))
                .appText(.display, weight: .bold)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text("账户、收益与研究，在一处看得更完整。"))
                .appText(.footnote)
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 16) {
            benefit("square.stack.3d.up.fill", L10n.text("账户全景"), L10n.text("汇总多个账户，统一查看资产与现金。"))
            benefit("chart.bar.xaxis", L10n.text("深入理解收益"), L10n.text("追踪收益来源、持仓贡献与历史表现。"))
            benefit("sparkles", L10n.text("AI 辅助研究"), L10n.text("结合持仓与公司信息，梳理投资问题。"))
        }
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).appText(.callout, weight: .semibold)
                Text(detail).appText(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("选择你的方案"))
                    .appText(.heading, weight: .bold)
                    .foregroundStyle(.white)
                Spacer()
                Text("USD").appText(.micro, weight: .semibold)
                    .foregroundStyle(CatfolioPalette.Paywall.ink)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.85), in: Capsule())
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                ForEach(PaywallPlan.allCases) { plan in
                    PaywallPlanCard(plan: plan, isSelected: selectedPlan == plan) {
                        selectedPlan = plan
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedPlan)
            Text(selectedPlan == .monthly
                 ? L10n.text("每月 $7.99，自动续订，可在 App Store 管理或取消。")
                 : L10n.text("一次支付 $129，终身使用，无需续订。"))
                .appText(.caption)
                .foregroundStyle(CatfolioPalette.Paywall.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .accessibilityIdentifier("paywall-billing-summary")
        }
    }

    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            Button { notice = .purchase } label: {
                Text(L10n.text("继续"))
                    .appText(.subheading, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
                    .background(CatfolioPalette.Paywall.action, in: RoundedRectangle(cornerRadius: 20))
                    .contentShape(RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("paywall-continue")
            Text(L10n.text("预览模式 · 不会扣费"))
                .appText(.micro)
                .foregroundStyle(CatfolioPalette.Paywall.secondaryInk)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [CatfolioPalette.Paywall.bottom.opacity(0), CatfolioPalette.Paywall.bottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

struct PaywallPlanCard: View {
    let plan: PaywallPlan
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 6) {
                    Text(plan == .monthly ? L10n.text("按月") : L10n.text("终身"))
                        .appText(.subheading, weight: .semibold)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 23, weight: .regular))
                        .foregroundStyle(isSelected ? CatfolioPalette.Paywall.action : CatfolioPalette.Paywall.secondaryInk.opacity(0.3))
                        .accessibilityHidden(true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(plan == .monthly ? "$7.99" : "$129")
                        .appNumber(.display, weight: .semibold, monospaced: false)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    if plan == .monthly {
                        Text(L10n.text("/月")).appText(.caption)
                            .foregroundStyle(CatfolioPalette.Paywall.secondaryInk)
                    }
                }
                Text(plan == .monthly ? L10n.text("按月续订") : L10n.text("一次付费，无需续订"))
                    .appText(.caption)
                    .foregroundStyle(CatfolioPalette.Paywall.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 32, alignment: .topLeading)
            }
            .foregroundStyle(CatfolioPalette.Paywall.ink)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(isSelected ? CatfolioPalette.Paywall.action : .white.opacity(0.6),
                                  lineWidth: isSelected ? 2.5 : 1)
            }
            .shadow(color: CatfolioPalette.Paywall.ink.opacity(isSelected ? 0.16 : 0.06), radius: 16, y: 7)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(plan.title + ", " + plan.priceDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("paywall-plan-\(plan.rawValue)")
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
        self == .monthly ? L10n.text("每月 7.99 美元") : L10n.text("一次支付 129 美元")
    }
}
