# CloudKit 生产部署与双设备验收

目标容器：`iCloud.com.catfolio.ios`；项目签名团队：`2G5PCQU652`。

## 管理凭据

一次性部署可以直接在 [CloudKit Console](https://icloud.developer.apple.com/) 登录开发者账户，使用 CloudKit Database 的部署界面。需要拥有该团队生产环境的编辑权限。

命令行工具另外需要 **CloudKit Management Token**。在 Console 的用户 Settings 中创建管理 Token，然后在本机终端执行：

```sh
xcrun cktool save-token --type management --method keychain
xcrun cktool get-teams
```

第一条命令不带 Token 参数，会使用安全输入提示，并将凭据保存在 macOS 钥匙串。直接在提示中粘贴 Token；不要写入项目、命令参数、日志或聊天。管理 Token 用于开发工具，不应打包进 App，也不是 App Store Connect API Key、CloudKit Web Services API Token 或持仓解密密钥。仅部署数据库结构不需要授予工具读取个人持仓的 User Token。

## 部署步骤

1. 登录 Console，确认当前团队与目标容器。
2. 导出并保留 Development 和 Production 当前结构。命令行访问可用时：

   ```sh
   xcrun cktool export-schema --team-id 2G5PCQU652 --container-id iCloud.com.catfolio.ios --environment development --output-file development-before.ckdb
   xcrun cktool export-schema --team-id 2G5PCQU652 --container-id iCloud.com.catfolio.ios --environment production --output-file production-before.ckdb
   ```

3. 在 Development 中新增或核对 `CatfolioEncryptedPortfolio`，其业务字段只有 `encryptedPayload`，类型为 **Asset**。保留容器已有类型、字段和权限。文本结构的新增片段如下，不能把片段当成整个容器结构覆盖导入：

   ```text
   RECORD TYPE CatfolioEncryptedPortfolio (
       encryptedPayload ASSET
   );
   ```

4. App 使用 Private Database，按已知 Record ID 直接读取，无需查询索引，也无需开放 Public Database 访问权限。开发结构通过验证后，进入 **Deploy Schema Changes**，核对完整差异，再部署到 Production。不要使用 Reset Environment / `reset-schema`，它会删除开发数据。
5. 在 Production 中重新核对记录类型及 Asset 字段。部署只复制结构，不复制开发数据。

## 双设备验收

两台设备使用同一 Apple 账户，启用 iCloud 和 iCloud 钥匙串，安装同一版访问 **Production** 的构建。开发签名构建也可以显式使用 Production；构建完成后必须核对实际签名中的 `com.apple.developer.icloud-container-environment`，不能只看 Xcode 的配置名称。

先通过设置界面确认同步开关和状态，再验证以下行为：

- 分别只开启 Key 同步或持仓同步，另一个开关保持关闭。
- Key 同步后第二台可使用对应连接，不显示或记录原始密钥。OAuth 登录仍可能需要重新授权。
- 持仓同步后对比账户、持仓数量和交易记录；使用可恢复的小范围变更验证反向同步。
- 关闭其中一台的同步并修改，再开启后确认恢复同步；确认关闭不会清空数据。
- 云端结构没有明文金额、持仓字段或解密密钥；数据为加密 Asset。

不要用重置真实组合或删除真实账户来做破坏性验收。删除、重置及故障注入已有自动化覆盖；真机的这些场景应使用明确可丢弃的测试数据。

验收记录应保留设备/系统、App 版本、实际 CloudKit 环境、测试时间和结果。无需保存原始 Key、Token 或完整个人账本。

## 当前进度（2026-10-16）

- **生产结构已部署。** 已通过 CloudKit Console 将团队 `2G5PCQU652`、容器 `iCloud.com.catfolio.ios` 的结构部署到 Production。新增 `CatfolioEncryptedPortfolio.encryptedPayload ASSET`；新类型未授予 Public Database 的 `GRANT` 权限，已有 `Users` 类型保持不变。
- 部署前结构保存在 [Development 备份](../CloudKit/development-before-2026-10-16.ckdb) 和 [Production 备份](../CloudKit/production-before-2026-10-16.ckdb)；[部署后的 Production 结构](../CloudKit/production.ckdb)及 [Console 成功截图](../CloudKit/production-deployed-2026-10-16.jpg)已保留。部署未复制开发环境的记录。
- 本次直接使用 Console 登录完成部署，**没有配置或使用 Management Token**。上面的命令行凭据流程仅供以后自动化使用。
- 验收设备已确定为 **Mac + iPhone 17 Pro**，不是两台 iPhone。两端使用 Debug 配置并显式覆盖 `CATFOLIO_ICLOUD_ENVIRONMENT=Production`，构建产物位于 `/tmp/catfolio-icloud-production/Build/Products/`。
- 验收期间发现 iPhone 安装路径变化，说明 App 曾被另一构建替换；当时无法读取旧构建的实际 CloudKit 环境，因此不能认定旧构建使用 Development。随后从当前工作区重新构建并核对签名中的 `Production` 环境，安装、启动成功，原数据和同步开关均保留，且复核了当前安装路径未再变化。本轮没有修改源代码，最新 Production iOS 构建通过。
- Mac Catalyst 的 Production 测试构建已签名成功。构建使用 `-destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' -allowProvisioningUpdates -allowProvisioningDeviceRegistration`；对应 profile 已包含这台 Mac。两端使用相同 App ID 和默认 Keychain access group。
- Mac 设置界面的两个同步开关已开启。2026-10-16 22:28（本机时间）观察到 Key 状态为 “Saved to iCloud Keychain. Other devices will receive it when system sync completes.”，持仓状态为 “Synced”。该 Key 状态本身仅表示本机已提交写入，后续跨设备证据如下。
- [Mac 同步状态截图](../CloudKit/mac-production-sync-2026-10-16.jpg)已保留。随后关闭 API Key 同步，持仓重试仍在 22:30 成功；再开启 API Key 同步也成功，验证两个开关独立运行。最终两项均保持开启。
- 用户已在 iPhone 开启两个开关，实际本地设置确认均为开启；两项同步的 Apple 账户归属哈希均与 Mac 相同。Mac 系统设置中的 iCloud「密码」同步也已确认开启。
- 两端 8 条有效凭据基线指纹一致，Mac 服务设置显示 6 项服务为 Configured；未读取原始 Key。指纹和配置状态证明配置一致性，不能证明每个服务的 API 调用可用。Mac 另有 IBKR Flex Token 格式无效提示，属于连接配置问题，不能将该连接记为 API 验证通过。
- Mac 原本为空的个人组合在重启和前台轮询后收到 **3 个账户、140 个持仓、3,870 笔交易、46 个快照**。最终两端的 `knownAccounts`、`positions`、`transactions`、`snapshots` 四个业务集合经规范化比较后内容完全一致。完整文档仅 `updatedAt` 和 `syncMetadata` 时钟元数据仍有差异，因此结论是业务数据收敛，不是最终 JSON 逐字相同。记录仅保留数量和比对结果，不记录账户名称、金额或完整账本。iPhone 的“已同步”由用户确认，Mac 的“Synced”由界面检查确认。
- **双向传递与还原已验证。** Mac 添加的临时账户显示名后缀到达了 iPhone，当时两端完整解码文档一致。随后 Mac 恢复了原名，最新 iPhone 副本确认测试后缀已消失，且两端名称均与测试前保存的原名完全一致。此前延迟与 Catfolio 不在手机前台、轮询暂停有关；现在无需用户继续操作。
- 早先手机副本的 3,871 条交易中有 1 条内容逐字节相同的重复行，唯一交易实际为 3,870 条。忽略测试改名影响的 `accountName` 后比较交易内容集合，确认还原后的全部唯一交易内容均保留，没有新增唯一交易丢失。此前将这条重复行描述为“新增交易、待核对”的判断已修正。
- 基础验收已覆盖真实 Mac+iPhone 正向恢复、反向改名传递及原名还原；完整故障注入、离线并发等矩阵未在真机逐项执行，不由当前结果推定通过。服务配置状态和凭据指纹一致也不代表所有外部 API 均已认证通过。
- 无敏感内容的验收证据见 [同步验收记录](../CloudKit/sync-acceptance-2026-10-16.json)。记录不包含原始密钥、凭据指纹、账户标识、名称、金额或账本内容。
- **基础 Mac+iPhone 正向、反向及还原验收已完成。** 本轮未修改源代码，最新 Production iOS 构建通过；未上传 TestFlight，未提交 Git commit。

参考：[Apple cktool 使用说明](https://developer.apple.com/icloud/ck-tool/)、[管理认证](https://developer.apple.com/icloud/cloudkit/automating/)、[生产结构部署](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)。
