import SwiftUI
import Observation

/// The view observes the same state for both sync features, while previews and
/// interaction tests use isolated models without opening a real iCloud account.
@MainActor
protocol CloudDataSyncSettingsModel: AnyObject, Observable {
    var isEnabled: Bool { get }
    var isBusy: Bool { get }
    var statusText: String { get }
    var lastSyncedAt: Date? { get }
    func setEnabled(_ enabled: Bool) async
    func refresh() async
}

extension CloudDataSyncSettingsModel {
    var lastSyncedAt: Date? { nil }
}

extension CloudCredentialSync: CloudDataSyncSettingsModel {}
extension CloudPortfolioSync: CloudDataSyncSettingsModel {}

struct CloudDataSettingsSection: View {
    let credentialSync: any CloudDataSyncSettingsModel
    let portfolioSync: any CloudDataSyncSettingsModel

    @MainActor
    init(credentialSync: (any CloudDataSyncSettingsModel)? = nil,
         portfolioSync: (any CloudDataSyncSettingsModel)? = nil) {
        self.credentialSync = credentialSync ?? CloudCredentialSync.shared
        self.portfolioSync = portfolioSync ?? CloudPortfolioSync.shared
    }

    var body: some View {
        SettingsSectionHeader(L10n.text("API 密钥"))
        CloudDataSyncSettingsControls(
            sync: credentialSync,
            title: L10n.text("同步 API 密钥"),
            icon: "key.icloud",
            identifier: "settings.icloud.credentials"
        )
        SettingsFootnote(L10n.text("通过 iCloud 钥匙串同步行情、AI、Trading 212 与 IBKR Flex 的密钥及必要连接设置。ChatGPT 登录和设备授权仍需在各设备重新连接。"))

        SettingsSectionHeader(L10n.text("账户与持仓"))
        CloudDataSyncSettingsControls(
            sync: portfolioSync,
            title: L10n.text("同步账户与持仓"),
            icon: "lock.icloud",
            identifier: "settings.icloud.portfolio"
        )
        SettingsFootnote(L10n.text("账户、持仓与交易记录在本机加密后上传到你的 iCloud 私有数据库。解密密钥通过 iCloud 钥匙串同步，不受 API 密钥开关影响。"))
        SettingsFootnote(L10n.text("在同一 Apple 账户的每台设备上分别开启，并启用 iCloud 钥匙串。关闭只暂停此设备，保留本机和云端数据，不更改其他设备。同步可能需要一些时间。"))
    }
}

/// Shared presentation, separate models and actions: one switch can never
/// change another feature's opt-in or the state of another device.
struct CloudDataSyncSettingsControls: View {
    @Environment(\.locale) private var locale
    let sync: any CloudDataSyncSettingsModel
    let title: String
    let icon: String
    let identifier: String

    var localizedStatusText: String { L10n.message(sync.statusText) }

    var enabled: Binding<Bool> {
        Binding(get: { sync.isEnabled }, set: { value in
            guard !sync.isBusy || !value else { return }
            Task { await sync.setEnabled(value) }
        })
    }

    func requestRefresh() {
        guard sync.isEnabled, !sync.isBusy else { return }
        Task { await sync.refresh() }
    }

    var body: some View {
        SettingsCard {
            SettingsToggleRow(icon: .symbol(icon), title: title, isOn: enabled)
                .disabled(sync.isBusy && !sync.isEnabled)
                .accessibilityIdentifier(identifier + ".enabled")

            // Status can contain an actionable error. Keep the full sentence in a
            // wrapping subtitle instead of squeezing it into a one-line value.
            SettingsRowContainer {
                SettingsRowLabel(icon: nil, title: L10n.text("同步状态"), subtitle: localizedStatusText)
            }
            .accessibilityIdentifier(identifier + ".status")

            if let lastSyncedAt = sync.lastSyncedAt {
                SettingsValueRow(
                    title: L10n.text("最近同步"),
                    value: lastSyncedAt.formatted(.dateTime.month().day().hour().minute().locale(locale)),
                    valueIsNumeric: false
                )
                .accessibilityIdentifier(identifier + ".lastSynced")
            }

            if sync.isEnabled {
                SettingsButtonRow(
                    icon: .symbol("arrow.clockwise"),
                    title: L10n.text("重试同步"),
                    showsChevron: false,
                    showsProgress: sync.isBusy,
                    action: requestRefresh
                )
                .disabled(sync.isBusy)
                .accessibilityIdentifier(identifier + ".retry")
            }
        }
    }
}
