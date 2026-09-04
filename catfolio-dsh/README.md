# catfolio-dsh

Catfolio（组合总览 + 收益对比 + 分析图表）作为 DeepSeek Harness Web 插件（dual-face Cordis plugin）。

- **服务端半面**（`lib/index.js`）：注册 `/catfolio/api/*` HTTP 路由，把嵌入式 demo 数据与分析引擎以 JSON 提供给浏览器；同时通过 `ctx.provide("catfolio", …)` 暴露 `catfolio` 服务。
- **客户端半面**（`lib/client.js`）：懒加载 CJS 工厂 bundle，向 harness 会话视图环注册三个 tab：
  - `catfolio-portfolio`（Portfolio 总览：指标卡、成本 vs 市值图、收益日历、持仓明细/ETF 穿透、成交量分布 hover）
  - `catfolio-returns`（收益对比：现金流镜像对比图、区间切换、AI 解读）
  - `catfolio-analytics`（分析图表：月度收益热图、回撤曲线、相关性矩阵、收益分布、归因瀑布、估值矩阵/明细表）
  - `catfolio-design`（设计面板：四个核心组件轮播演示——成本 vs 市值、收益日历、回撤曲线、持仓明细，本地假数据）

## 数据与引擎

- `data/`：嵌入式 demo 数据（snapshot / lab history / income / sp500 holdings），由原 Python demo 生成，与 `CATFOLIO_PUBLIC_DEMO=1` 下 FastAPI 的输出逐字段一致（见 `scripts/verify-payloads.mjs` 的对照验证，9 个 payload 全绿）。
- `src/core/engine.ts`：纯 TypeScript 分析引擎（`portfolioSummary` / `holdingsDetail` / `etfLookthrough` / `comparisonPayload` / `profitCalendarPayload` / `holdingVolumeProfile` / `analyticsPayload` / `holdingsHeatmap` 等），全部为确定性纯函数 —— 这是未来替换为 Rust 核心（N-API addon）的接缝：只要实现同一 `CatfolioEngine` 接口即可。

## 构建与安装

```bash
npm install            # 安装 esbuild / echarts / lightweight-charts
npm run build          # 产出 dist/（lib/index.js + lib/client.js + data/ + package.json）
npm run verify:payloads   # 与捕获的 Python 输出对照，必须全绿
```

安装到 web profile（客户端 bundle 会被增量发现，服务端路由需重启 dsh web 才生效）：

```bash
cp -R dist/* ~/.dsh/profiles/node_modules/catfolio-dsh/
```

并在 `~/.dsh/profiles/web/cordis.patch.yml` 中追加：

```yaml
- insert:
    - id: catfolio
      name: 'catfolio-dsh'
```

重启 `dsh web` 并刷新浏览器页面后，会话头部视图环会出现 **Portfolio**、**收益对比**、**分析图表**、**设计面板** 四个 tab。

## AI 解读：由 harness 接管

收益对比页的「AI 解读」按钮不再需要 Catfolio 自己的 API key——服务端注入 harness 的 `ctx.llm` 服务（`inject: ["webServer", "llm"]`），用 `ctx.llm.stream()` + `BlockAssembler` 调用 harness 已配置的模型（默认 DeepSeek，`~/.dsh/settings.yaml` 的 `agent-default-model`，key 存于 `~/.dsh/.credentials.yaml`）。

- 调用参数：`provider`/`model` 从 `ctx.llm.listProviders()` 动态取第一个可用 provider；prompt 与 Python 版 `returns_explanation` 一致（组合 vs 8 基准 + 最近 12 个月月度收益）。
- 失败兜底：LLM 服务不可用或调用抛错时回退到确定性 demo 文本，UI 永不中断。
- 切换模型/配 key：在 harness 的模型设置界面操作即可，插件自动跟随，无需改插件配置。

## 开发

- 改引擎/服务端：`src/server`、`src/core` → `npm run build` → 重新拷贝 dist → 重启 dsh web（服务端模块不热重载）。
- 改客户端：`src/client` → 重新构建；`/plugins/catfolio-dsh/client.js` 带 rev 哈希，浏览器刷新即可取得新版本。
