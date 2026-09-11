# Catfolio 官网

以 Atlas 官网为视觉参考的独立静态官网。使用现有 Catfolio 品牌、原生 App 截图和本地字体，无外部运行依赖。

本地预览：在此目录运行 `python3 -m http.server 4318 --bind 127.0.0.1`。

下载按钮目前打开发布状态对话框。上线前需替换为正式 App Store / TestFlight 链接，并确认对外使用的截图与发布版本一致。当前未部署。

## 功能截图（2026-09-09）

官网功能区现为 16 个独立模块：将原清单最后一类拆为公开投资者模拟、个性化与本地数据。支持四类筛选、完整截图弹窗、左右切换和 Escape 退出。

- `features.json`：图文内容清单；页面静态 HTML 与其对应，修改内容时同步更新两者。
- `assets/features/`：官网引用的截图副本，运行时不依赖临时目录。
- accounts、investors、preferences、sentiment、research、today、ai：2026-09-09 从已安装的 iOS 模拟器版本补拍，账户使用演示模式。
- overview、etf、detail、attention、screener、history：复用已有开发验证截图。
- returns：复用 `docs/screenshots/ios-returns-mode-switcher.png`。
- oi：Yahoo OI 布局演示截图，不是真实期权快照。
- financial：盈利历史 SwiftUI 组件的测试样本渲染，不是真实公司财报。

每个模块显示截图状态与覆盖边界。上线前可按文件名替换成统一发布版本截图；无需重新设计页面。

本次验证：16 个唯一模块与对应图片文件、分类计数（5/4/5/2）、放大及前后切换、键盘左右切换与 Escape、移动端无横向溢出、浏览器无控制台错误。未修改原生 App 或金融计算。

## 个股与收支专区
新增 stock-research、cash-history、upcoming 三个区块。个股七项与历史四项分别展开；税务、税损模拟、拍照导入明确为待开放/需求规划。orders.png 是 2026-09-09 中文演示账户交易页截图。其余子功能沿用所属模块截图，未开放功能不伪造截图。

新增 currency-language 专区：汇率盈亏来源状态、中英文及跟随系统、九种显示货币自动折算。核对来源为 VolumeProfileView.swift、Localization.swift、DesignSystem.swift。

2026-09-10：新增市场轮动、板块轮动、策略编曲家，共19模块。后两项采用已检查的原生开发截图 /tmp/catfolio-rotation-ios.png 和 /tmp/catfolio-policy-editor.png；市场轮动不以其他图替代，标记待补。ReturnsView.swift 税务入口仍 disabled，保持未开放。
