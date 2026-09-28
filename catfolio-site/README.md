# Catfolio 官网

独立静态中英文官网，沿用 Atlas 风格和 Catfolio 原生 App 截图。

## 维护

- `index.html`：中文页面及整体结构。
- `features.json` / `features.en.json`：35 项功能、截图路径、说明和数据口径。
- `translations.en.json`：页面英文翻译；`en.html` 由脚本生成。
- 修改内容后运行 `python3 catfolio-site/render_features.py`（在仓库根目录运行）。
- 本地预览：`python3 -m http.server 4318 --bind 127.0.0.1 --directory catfolio-site`。

网站无需 JavaScript 也能浏览完整内容；JavaScript 提供分类、截图弹窗和旧锚点兼容。

## 内容结构

2026-09-21 审计：21 个区块收为 7 个，取消专题与图库之间的重复介绍。每项功能只显示标题和一句说明，细节与数据口径按需展开。

- 今日收益与组合透视合并为一项。
- 自动汇率更新与显示货币换算合并为一项。
- 安全说明集中在隐私区。
- 系统小组件保留文字说明；SnapTrade 个人 API 只读连接归入账户管理，税务及税损模拟、拍照导入列为 Coming soon。
- 原来的专题链接跳转至对应图库条目。

## 截图边界

配图来自 iOS 模拟器与虚构演示组合。`assets/refresh/` 是功能截图，`assets/zh-latest/` 与 `assets/en-latest/` 用于对应语言的部分页面。

英文图库仍包含中文界面截图，页面已说明，不能视作完整英文截图集。行情解读卡片仍为重试状态；财报电话会卡片展示入口，非分析结果。股息配图展示历史记录，非预测结果。小组件尚无已核实截图。本次文案审计没有补拍这些界面。

收益对比使用 `returns-comparison.png`，避免把首页或空持仓状态用作收益截图。`build_vercel.py` 检查引用资产及两个首页展示图的内容哈希是否不同。

## 构建与发布

线上：https://catfolio-app.vercel.app/。英文 `/`，中文 `/zh`。

在仓库根目录构建：

```sh
python3 catfolio-site/build_vercel.py
```

随后在 **`catfolio-site/dist`** 目录发布：

```sh
npx vercel deploy --prod
```

目标项目为 `irrwoods-projects/catfolio`。不要从仓库根目录运行部署；根目录可能关联其他项目。构建保留 `dist/.vercel`，仅复制官网用到的资源。下载入口尚未配置 App Store / TestFlight 地址。
