# iOS iCloud 偏好同步

更新：2026-09-14。入口在「设置 → iCloud → 同步偏好设置」。

## 用户行为

- 每台设备分别开启，默认关闭；开关本身只保存到本机。
- 开启时采用云端已经存在的偏好。云端缺少的项目保留本机值，并补到偏好存储中。
- 开启后，只推送实际改变的允许列表项目，避免无关的本地设置变动用旧快照覆盖云端新值。
- 关闭后停止后续收发，保留本机与云端已有设置；已经交给系统的更新无法撤回。
- 初次同步、账户切换、缺少明确变更键的通知，都不会因为云端缺键而删除本地值。只有服务器明确通知某键被删除，才传播删除。

同步范围：显示货币、外观、公司名称、触控反馈、税年、持仓排序、研究筛选数量/关注度、选股规则和提示词。语言、账户选择、模拟模式、个人账本、成交记录和凭据不在同步列表内。

## 状态与实现

页面区分未开启、由系统自动同步、暂时无法同步、存储限额和设置过长。最近接收时间仅来自有效的入站通知；重试或 `synchronize()` 返回 true 都不会制造“同步完成”的记录。系统自行安排跨设备传递，参见 Apple 的 [synchronize 文档](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/synchronize%28%29)。

- `CloudPreferences.swift`：允许列表、纯合并函数、主线程上的可观察同步控制器，以及可替换的存储边界。
- `SettingsView.swift`：复用现有设置页的开关、状态行、重试按钮及说明，提供中英文文案。
- `CatfolioIOSApp.swift`：启动注册通知；回到前台时检查系统存储连接。
- `CatfolioIOS.entitlements`：仅声明 `com.apple.developer.ubiquity-kvstore-identifier`，使用 `$(TeamIdentifierPrefix)$(CFBundleIdentifier)`。
- Xcode 主 App 的 Debug 与 Release 均绑定该 entitlement，并启用 iCloud capability。使用 Key-value storage，无需增加 CloudKit 数据库或文档容器，参见 Apple 的 [权限说明](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.ubiquity-kvstore-identifier)。

本机保留超出单值上限的内容，界面提示未同步的原因。额度通知不触发删除；请求成功不被当作额度已经恢复的确认。

## 验证

`CloudPreferencesTests` 使用独立 UserDefaults 和内存云存储，测试默认关闭、合并、停止收发、通知去回写、删除边界、账户变化、错误重试及大小限制。原来直接写真实 `NSUbiquitousKeyValueStore.default` 的测试改为隔离测试。

`SettingsInteractionTests.testCloudSettingsScreenshots` 渲染实际设置组件，保存中文关闭、英文开启、中文错误、英文深色大字体四种截图。

构建、测试及截图证据记录在 [iOS 审查修复记录](audits/ios-2026-09-13/FIXES.md)。真实同一 Apple 账户的两台设备之间，离线重连与实际传递仍需端到端验收；模拟存储测试和签名构建不能替代该验收。本次未上传新版本。
