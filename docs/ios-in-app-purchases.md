# Catfolio 内购准备

更新：2026-09-28。用户要求：准备好，暂不上线。

## 当前状态

- 两个商品已在 App Store Connect 创建，均为 **Prepare for Submission**，未提交审核。
- 美国价格已保存：月付 USD 7.99、终身 USD 129.00；商品中英文名称和描述已保存。
- 销售地区尚未配置，家庭共享未启用。
- iOS 1.0 (20) 的付费墙仍为预览，未接入 StoreKit，也没有限制现有功能。
- 不提交审核、不发布、不启用真实付费入口。

## 商品配置

App Bundle ID：`com.catfolio.ios`。App Store Connect App ID：`6810656291`。以下 Product ID 已创建。

| 字段 | 月订阅 | 终身版 |
| --- | --- | --- |
| Reference Name | Catfolio Pro Monthly | Catfolio Pro Lifetime |
| Product ID | `com.catfolio.ios.pro.monthly` | `com.catfolio.ios.pro.lifetime` |
| Apple ID | `6817086676` | `6817085987` |
| 类型 | Auto-Renewable Subscription | Non-Consumable |
| Subscription Group | Catfolio Pro | 不适用 |
| 时长 | 1 Month | 永久，一次购买 |
| 已保存美国价格 | USD 7.99 | USD 129.00 |

已核实 Apple 支持以上精确价格点，其他地区价格采用 Apple 自动换算。暂不配置试用、促销或家庭共享。最终界面价格由 StoreKit 的 `Product.displayPrice` 提供。

## 商品本地化（已保存）

| 字段 | English (U.S.) | 简体中文 |
| --- | --- | --- |
| 订阅组名称 | Catfolio Pro | Catfolio Pro |
| 月订阅名称 | Catfolio Pro Monthly | Catfolio Pro 月度订阅 |
| 月订阅描述 | Monthly access to Catfolio Pro features. | 按月使用 Catfolio Pro 功能。 |
| 终身版名称 | Catfolio Pro Lifetime | Catfolio Pro 终身版 |
| 终身版描述 | Lifetime Catfolio Pro access with a one-time purchase. | 一次购买，永久使用 Catfolio Pro 功能。 |

## 上线前仍需完成

1. 配置销售地区；订阅组 ID 为 `22421987`。上线前复核商品价格与本地化。
2. 明确 Pro 功能边界；当前预览中的账户、收益和 AI 权益文案不代表已实现付费限制。
3. 接入 StoreKit 2：加载商品、购买、验证交易、完成交易、监听交易更新、恢复购买和刷新权益。
4. 补全付费墙的隐私政策与使用条款入口；行情和 AI 服务商费用不包含在 Pro 价格中。
5. 沙盒验证成功、取消、待批准、恢复、续订、到期及退款；月订阅和终身版解锁同一 Pro 权益。
6. 使用真实购买流程截图准备审核材料。现有预览截图不能作为已完成内购的证明。
7. 获得后续上线指令后再提交审核并发布。

## 官方参考

- [创建非消耗型内购](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-consumable-or-non-consumable-in-app-purchases/)
- [创建自动续期订阅](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/)
- [设置内购价格](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/set-a-price-for-an-in-app-purchase/)

## 后台入口

- [月订阅](https://appstoreconnect.apple.com/apps/6810656291/distribution/subscriptions/6817086676)
- [终身版](https://appstoreconnect.apple.com/apps/6810656291/distribution/iaps/6817085987)
- [订阅组](https://appstoreconnect.apple.com/apps/6810656291/distribution/subscription-groups/22421987)
