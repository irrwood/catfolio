# Catfolio 省力改造方案

> 测量日期：2026-08-22 · 分支 `codex/open-source-v1`
> 原则：**不重写**。1.3 万行 Python、171 个测试 1.65 秒全绿，安全网足够好，做定点手术即可。

---

## 0. 先看体检结果

### 代码规模（不含 .venv / 构建产物）

| 项 | 数值 |
|---|---|
| Python 应用代码 | 13,377 行 |
| Git 追踪文件 | 184 个 / 45 MB |
| 测试 | 171 个，1.65 秒全绿 |
| 前端 | 纯 vanilla JS + CSS，无构建步骤 |
| 页面路由 | 12 个（9 个进侧边栏） |

**结论：这个规模不该觉得"大"。** 痛感来自下面四处具体的位置，不是来自体量。

### 实测性能（冷启动，本机）

| 端点 | 耗时 | 体积 |
|---|---|---|
| **`/api/returns`** | **23.47 s** | **2.90 MB** |
| `/settings`（页面） | 0.95 s | 73 KB |
| `/api/analytics` | 0.90 s | 24 KB |
| `/api/holdings` | 0.008 s | 143 KB |
| `/api/market` | 0.012 s | 103 KB |
| 其余页面 | 0.02–0.04 s | 44–56 KB |

热缓存后 `/api/returns` 降到 0.15 s，但 `@cached(ttl=90)` 意味着**每 90 秒过期一次，下一个访客再付 23 秒**。

---

## 第 1 刀：`/api/returns` 的 23 秒（收益最大，风险最低）

### 根因（已逐项计时确认）

`app/routes/api.py:384` 的 `api_returns()`：

```python
cash_flow_benchmarks = {symbol: cash_flow_mirror_vs_benchmark(symbol) for symbol in BENCHMARKS}
```

`BENCHMARKS` 有 8 个：`SPY QQQ VTI VOO DIA IWM VEU GLD`。逐个计时：

```
cumulative_vs_benchmark        0.55s  0.04MB
cash_flow_mirror(  SPY)        2.53s  0.33MB
cash_flow_mirror(  QQQ)        2.50s  0.33MB
cash_flow_mirror(  VTI)        2.48s  0.33MB
cash_flow_mirror(  VOO)        3.03s  0.33MB
cash_flow_mirror(  DIA)        2.60s  0.33MB
cash_flow_mirror(  IWM)        2.95s  0.33MB
cash_flow_mirror(  VEU)        2.53s  0.33MB
cash_flow_mirror(  GLD)        2.46s  0.33MB
cumulative_multi_benchmark     0.00s  0.06MB
```

**而 `/returns` 页面默认只显示 SPY 一条线**（`app/routes/returns.py:38`，`comparison-metric-note` 硬编码 SPY）。

更关键的是：cProfile 打在**单次**调用上，暴露出成本根本不在数值计算：

```
6.53s  cash_flow_mirror_vs_benchmark
 6.35s   └─ ensure_history_symbols          ← 97%
  4.83s      ├─ json.dumps                  ← 74%
  0.88s      └─ urlopen (Yahoo)             ← 13%
```

真凶在 `app/lab.py:664`，`ensure_history_symbols()` 的最后一行：

```python
LAB_HISTORY_CACHE.write_text(json.dumps(history, ensure_ascii=False, indent=2), encoding="utf-8")
```

那个缓存文件（`outputs/portfolio_analysis_v2/lab_history_data.json`）是 **45.9 MB**，156 个 symbol / 186,458 行价格。

`cash_flow_mirror_vs_benchmark(symbol)` 在第 1227 行调 `ensure_history_symbols(set(symbol_currency) | {symbol})`。每个 benchmark 只往缓存里加**一个**新 symbol（QQQ、VTI、VOO…），然后**把整个 45.9 MB 重新序列化并全量落盘**。

**8 个 benchmark = 8 次 Yahoo 请求 + 8 次 45.9 MB 全量重写 = 单请求写 367 MB 磁盘。**

实测那一行的成本：

| 写法 | 耗时 | 产出体积 |
|---|---|---|
| `json.dumps(indent=2)`（现状） | **1.32 s** | 45.9 MB |
| `json.dumps(compact)` | 0.38 s | 30.3 MB |

（同时排除了其它 IO 嫌疑：`_read_trade_transactions()` 只要 0.03 s，`get_history_cached()` 只要 0.23 s。而 `time.sleep(0.04)` 还叠在每个 symbol 的抓取上。）

### 改法（三个层次，可只做第一层）

**1a. 只算要用的那个**（改 1 行，10 分钟）

```python
# api.py:388 —— 默认只算 SPY，其余按需
cash_flow_mirror = cash_flow_mirror_vs_benchmark("SPY")
cash_flow_benchmarks = {"SPY": cash_flow_mirror}
```

再加一个 `GET /api/returns/benchmark/{symbol}` 端点，前端切换 benchmark 时才请求。

> 预期：23.5 s → **约 3.1 s**，2.90 MB → **约 0.43 MB**

**1b. 删掉 `indent=2`**（改 10 个字符，1 分钟）

`app/lab.py:664`：

```python
LAB_HISTORY_CACHE.write_text(json.dumps(history, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
```

> 收益：每次写 1.32 s → 0.38 s，文件 45.9 MB → 30.3 MB。
> 这是全项目性价比最高的一次改动，没有之一。缓存文件本来就不是给人读的。

**1c. 把 `ensure_history_symbols` 提到循环外**（约 1 小时）

现在每个 benchmark 各自触发一次「补一个 symbol + 全量重写」。改成先把 8 个 benchmark 符号一次性传进去，补齐后再进循环：

```python
ensure_history_symbols(set(all_trade_symbols) | set(BENCHMARKS))   # 只写一次
for symbol in BENCHMARKS:
    ...  # 此时 missing 为空，走 lab.py:641 的快速返回
```

`ensure_history_symbols` 第 641–642 行本来就有 `if not missing: return history` 的快速路径——提上来之后后面 7 次调用全部命中它，7 次全量重写直接消失。

顺带：抓取循环里的 `time.sleep(0.04)`（第 655 行）可以换成小并发池，网络那 0.88 s/symbol 也能压掉大半。

> 预期：1a + 1b + 1c 合起来，23.5 s → **约 1 s**

**1d. 调 TTL**（改 1 个数字）

`ttl=90` 对一个日频数据的分析工具毫无意义——行情一天才变几次。改 `ttl=900`，并保留 `clear_all()` 在刷新后主动失效的现有机制（`api.py:406` 已经这么做了）。

### 风险与验证

- **风险：低。** 纯计算重排，不碰算法本身。
- 现有测试：`tests/test_portfolio_chart_hover.py`、`tests/test_app_contracts.py` 覆盖返回结构。
- 额外验证：改前存一份 `/api/returns` 的 JSON，改后逐字段 diff，确认 SPY 数值完全一致。
- 前端要同步改 `app/static/returns.js`（benchmark 切换改成异步请求）——这是这一刀唯一需要改前端的地方。

---

## 第 2 刀：其它性能小账（半天）

| 问题 | 位置 | 改法 |
|---|---|---|
| `echarts.min.js` **1.0 MB** 同步阻塞 | `app/routes/lab.py:13` | 加 `defer`；或图表容器进视口再动态 `import()`。ECharts 只有 `/lab` `/analytics` 用到 |
| `/settings` 冷启动 0.95 s | `app/routes/settings.py:36–46` | 10 次 `secret_value()` → 每次 fork 一个 macOS `security` 子进程（约 33 ms×10 + 开销）。`data_store.py:239` 已做进程内 memo，但**首次仍然串行**。改成一次 `security` 批量查询，或启动时后台预热 |
| `/api/analytics` 0.90 s | `app/routes/api.py:237` | 同样是 `cumulative_vs_benchmark` + `cash_flow_mirror`，第 1 刀做完自动受益 |
| `/api/holdings` 143 KB | `app/routes/api.py` | 体积大但只要 8 ms，**不用管**。真要瘦身就加 `?fields=` 投影 |

---

## 第 3 刀：删死代码（半天，纯减法）

### v4 布局

`app/components.py` 782 行里，`wrap_v4_layout`（351–563 行）**213 行**只为 `?ui=v4` 这一个逃生口服务。加上 `app/static/v4.css` **46 KB**。

引用点只有 5 处：
```
app/components.py:351, 411, 545, 739, 741
app/routes/report.py:12
tests/test_canonical_urls.py:61
tests/test_report_demo.py:33,36
tests/test_settings_demo.py:352,376
```

**改法**：删 `wrap_v4_layout` + `v4.css`，`render_layout` 直接返回 v5，同步删掉那几个测试断言。

> 收益：`components.py` 少 27%，静态资源少 46 KB，以后改布局只有一个地方要动。
> **风险：需要你确认** —— `?ui=v4` 你自己还在用吗？如果只是历史包袱就可以删。

### 其它候选

- `app/static/component-demo*.{js,css,html}` + `sites/catfolio-component-demo/`（465 MB）——是临时演示还是要留？
- `desktop.py` / `desktop_test.py` / `catfolio.spec` / `catfolio-test.spec`：PyInstaller 桌面打包，还活着吗？

---

## 第 4 刀：模板层（1–2 天，让以后改 UI 省力）

### 现状痛点

HTML 以 f-string 内嵌在路由文件里，改一个按钮要在 Python 字符串里翻找：

| 文件 | 大小 | 其中 HTML |
|---|---|---|
| `app/routes/settings.py` | 24 KB | 大部分 |
| `app/routes/lab.py` | 17 KB | 大部分 |
| `app/routes/bank.py` | 17 KB | 大部分 |
| `app/routes/strategy.py` | 16 KB | 大部分 |
| `app/components.py` | 53 KB | 含 SVG sprite + 两套 layout |

没有语法高亮、没有格式化、没有 lint，`{}` 还要转义成 `{{}}`。

### 改法

FastAPI 原生支持 Jinja2，**不引入构建步骤**：

```
app/templates/
  base.html          # 从 wrap_v5_layout 搬过来
  _sidebar.html
  _icons.svg         # 从 components.py 的 _HUGEICON_SYMBOLS 搬出来
  pages/
    lab.html  returns.html  settings.html  bank.html  ...
```

**省力关键：一次搬一个页面，每搬完跑一次测试。** 171 个测试大多断言 HTML 里的关键字符串，搬运正确它们就绿。不要一次全搬。

建议顺序（从简单到复杂）：`returns` → `import` → `strategy` → `heatmap` → `ai` → `bank` → `lab` → `settings`。

### i18n 的顺带好处

现在 `app/i18n.py` 是 68 KB / 1082 行的字典 + `t_block()` **全页文本替换**——靠子串匹配翻译整页 HTML，脆弱（注释里自己就写了"substring collisions"）。搬到模板后可以逐步换成 `{{ t('key') }}` 键值查找。**但这一步单独做，不要和搬模板混在一起。**

---

## 第 5 刀：9 页合 3 页（2–3 天，改动最大）

### 现状

侧边栏（`app/components.py:548`）：

```
分析: /lab  /returns  /analytics  /strategy  /heatmap  /ai  /bank
数据: /import  /settings
```

同一份持仓数据在 `/lab` `/analytics` `/heatmap` `/returns` `/strategy` 各取一遍，各自一套 CSS+JS。想看全貌要点 4 次。

### 建议信息架构

| 新页面 | 合并自 | 说明 |
|---|---|---|
| **总览** | `/lab` + `/returns` 的摘要卡 | 一屏看完：市值、盈亏、收益日历、vs SPY |
| **分析** | `/analytics` + `/heatmap` + `/strategy` + `/ai` | 顶部 tab 切换，共用一次数据加载 |
| **数据源** | `/bank` + `/import` + `/settings` | 连接、导入、密钥都在一处 |

旧 URL 全部 301 到新位置，书签不断。

### 前置条件

**这一步建议放在第 4 刀之后。** 有了模板层，合并页面就是重组模板 + 抽一个共享的 `dataLayer.js`；没有模板层，就是在 Python 字符串里做大手术。

顺带解决前端重复：`escapeHtml` 定义了 3 次，`fmtNum` 3 次，`fmtPct` 3 次，散在各 JS 里。合并时抽一个 `app/static/common.js`。

---

## 第 6 刀：清仓库（10 分钟）

未追踪的构建垃圾：

```
sites/          465 MB
dist/           154 MB
outputs/         58 MB
dist-intel/      34 MB
build/           31 MB
build-intel/     16 MB
releases/       6.1 MB
                ------
                 764 MB
```

`.gitignore` 已经覆盖了大部分（`sites/` 除外），所以 **git 本身是干净的**（184 文件 / 45 MB）。只是本地目录看着乱。

改法：确认哪些能删后 `rm -rf`，并给 `sites/` 补一条 `.gitignore`。另外 `.DS_Store` 虽然在 `.gitignore` 里，但项目里散着好几个（根目录 20 KB、`v3_backend/` 10 KB、`app/` 10 KB）——`find . -name .DS_Store -delete` 清一下。

---

## 推荐执行顺序

```
第 1 刀  /api/returns          1 小时    ★★★★★  23s → 0.6s，风险最低
第 6 刀  清仓库                10 分钟   ★★★★    纯删除，零风险
第 3 刀  删 v4                 半天      ★★★★    纯减法，需你确认 ?ui=v4
第 2 刀  echarts + settings    半天      ★★★
第 4 刀  Jinja2 模板层         1-2 天    ★★★     一次一页，测试保驾
第 5 刀  9 页合 3 页           2-3 天    ★★      改动最大，放最后
```

**每一刀都能独立完成、独立提交、随时停。** 前三刀加起来不到一天，能拿掉大部分痛感。

---

## 需要你先确认的三件事

1. **`?ui=v4` 还在用吗？** 决定第 3 刀能不能做。
2. **`sites/catfolio-component-demo/`（465 MB）和 `component-demo*` 是什么？** 临时演示还是要留的东西。
3. **桌面打包（`desktop.py` / `catfolio.spec` / PyInstaller）还活着吗？** 决定 `build*` `dist*` 能不能清。

---

## 附录：Rust 重写 / GPUI 评估

> 2026-08-22 讨论后追加。结论：**不建议**，但理由不是「Rust 不好」。

### 为什么 Rust 修不了这个项目的慢

第 1 刀的 profile 已经说明，23.5 秒的构成是：

| 成分 | 占比 | Rust 能改善吗 |
|---|---|---|
| 重复的 JSON 全量序列化 | 约 11 s | 快 5–10×，但**没修根因** |
| 重复的 45.9 MB 磁盘写 | 约 7 s | 几乎不变（IO bound） |
| 串行 Yahoo 网络请求 | 约 7 s | **完全不变** |
| 实际数值计算 | < 1 s | 快 20–50×，但基数太小 |

**语言换掉只是把 bug 藏起来。** 你还是在每次请求里序列化 367 MB、还是在串行发 8 个网络请求；等数据涨到三倍，它会重新变慢，而语言红利已经吃完了。

（顺带：`requirements.txt` 里没有 numpy / pandas，数值全是纯 Python 循环——这本来确实是 Rust 的主场，但 profile 证明它不在热路径上。真要提速，上 numpy 比上 Rust 省事得多。）

对照成本：

| 方案 | 工作量 | `/api/returns` 结果 |
|---|---|---|
| 第 1 刀（删 indent + 提循环 + 只算 SPY） | **约 1 小时** | 23.5 s → 约 1 s |
| Rust 重写 | 6–12 个月 | 也快，但根因还在 |

### GPUI 具体到本项目的五个硬冲突

**1. GPUI 没有任何图表能力 —— 这是致命项**

Zed 是编辑器，不需要画图。而本项目的本质就是图表：

```
ECharts：line ×15  bar ×5  scatter ×4  heatmap ×2  treemap ×1  custom ×2
lightweight-charts：金融级 K 线 + 十字光标 + 直方图
另有：收益日历 DOM 网格、volume profile
```

全部要用图元手绘：坐标轴、刻度、tooltip、十字光标跟随、时间区间缩放、hover 高亮、图例联动。ECharts 压缩后 1 MB 装的就是这些。**单这一项就是数月，且大概率不如 ECharts 好用。**

**2. 会砍掉三个交付目标里的两个**

当前一套代码三个出口：

| 出口 | 入口文件 | GPUI 之后 |
|---|---|---|
| 本地 web | `v3_backend/run.sh` → uvicorn | ✗ 废弃 |
| 原生 macOS 桌面 | `v3_backend/desktop.py`（pywebview + PyInstaller） | ✓ 保留 |
| Vercel 公开只读 demo | `index.py` + `vercel.json` | ✗ 废弃 |

**3. 17 个外部集成要全部重来**

9 个 AI 提供商（OpenAI / DeepSeek / Moonshot / xAI / Gemini / 通义 / 智谱 / OpenRouter / Massive，均带流式）、Plaid（3 套环境）、IMAP 邮件扫描、Yahoo、FMP、Finnhub、Telegram、Vanguard。

**4. 无障碍会倒退**

现有代码里 `role="grid"` / `aria-live` / `aria-roledescription` / `aria-pressed` 铺得较全，浏览器白送。GPUI 这块本来就弱，全部要自己补。

**5. GPUI 自身成熟度**

主要活在 Zed 仓库内，文档稀疏，通常需挂 git 依赖，API 随 Zed 需求演进；平台上 macOS 最成熟、Linux 次之、Windows 最弱。**动手前务必自行核实当前状态，勿依赖本文档的记忆性描述。**

### 如果确实想要 Rust / 原生，正确的打法

**想要原生桌面 → Tauri，不是 GPUI。**

现有架构是「Python 后端 + WKWebView 前端」，Tauri 是「Rust 后端 + WebView 前端」——**结构同构，只换后端语言**。所有 HTML/CSS/JS/ECharts 原样搬运，图表一行不用重写。单文件分发，体积远小于 PyInstaller，启动更快。这是从现状通向 Rust 且不用重造图表的唯一路径。

**想在现有项目里放 Rust → PyO3 扩展。**

把数据层（CSV 解析、缓存读写、Yahoo 客户端）做成 Rust 扩展，FastAPI 照旧。但 `indent=2` 删掉之后，这一步收益已经不大。

**想学 Rust → 那就写，这是正当理由，不需要用性能找借口。** 但那时它是个新项目而非本项目的重构，工期按 6–12 个月排，且必须接受图表那关。

### 建议

**先花 1 小时做完第 1 刀，再重新评估。** 修完之后这个项目还慢不慢，那时的判断会准确得多——现在等于是拿「一个能一小时修好的 bug」当重写的理由。

---

## 附录二：Electron 评估

> 2026-08-22 讨论后追加。结论：**排在 Sparkle 和 Tauri 之后**。

### 本项目 2026-06-12 已经做过这个决定

`docs/desktop-app-plan.md` 技术选型一节：

> （备选：Tauri / Electron + Python sidecar，外壳更精致、可自动更新，但要上额外工具链。**等需要「正经发布 + 自动更新」时再考虑，当前不必要**。）

所以问题不是「Electron 好不好」，而是**当初写下的触发条件是否已经到了**。

同一份文档第 77–78 行，两个仍未勾选的 TODO：

- [ ] 代码签名 + 公证 —— 现状 `catfolio.spec:124` 是 `codesign_identity=None`
- [ ] 自动更新 —— 「自用可手动换包；要分发再考虑 Sparkle 或换 Tauri」

### 体积对比（实测现状 vs 估算）

| | 现在（pywebview + PyInstaller） | Electron + Python sidecar |
|---|---|---|
| `.app` | **38 MB**（实测） | 约 200 MB |
| DMG arm64 | **21 MB**（实测） | 约 110 MB |
| DMG x86_64 | 23 MB（实测） | 约 110 MB |
| 内存基线 | WKWebView，共享系统进程 | Chromium 约 150–300 MB |
| 构建工具链 | PyInstaller | PyInstaller + Node/npm + electron-builder |

**关键**：38 MB 里是 CPython 运行时 + 依赖 + 代码，**WKWebView 占 0 字节**（系统框架）。换 Electron 等于**同时打包 Chromium 和 CPython**，约 5 倍膨胀。

另有一项非理论性的工程成本：把 PyInstaller 产物作为 sidecar 嵌入 Electron 后，嵌套二进制的 codesign + notarization 相当繁琐。

### Electron 的真实优势

1. **跨平台单一渲染引擎** —— pywebview 在 macOS 用 WKWebView、Windows 用 WebView2、Linux 用 WebKitGTK，三个引擎三套行为；Electron 处处 Chromium。**这是它最大的价值。**
2. **自动更新** —— `electron-updater` 成熟可靠。
3. **electron-builder 一条龙** —— mac 公证、Windows NSIS/MSI、Linux AppImage/deb。
4. **原生集成** —— 菜单栏、托盘、通知、深链接、文件对话框，均强于 pywebview。

### 但优势 1 在当前平台策略下不成立

`docs/desktop-app-plan.md` 开头：

> 目标平台：**仅 macOS**（所以 Keychain 走系统 `security` CLI 的现状保留，不做跨平台改造）

密钥层是**有意**锁死 macOS 的。Electron 最大的卖点因此归零。

且需注意：**要上 Windows/Linux，无论换不换外壳都得先重做密钥层**——那是 `app/data_store.py:257 _read_secret()` 的工作（`keyring` 已在 `requirements.txt` 里），Electron 替代不了。

### 选型排序

| 需求 | 选择 | 代价 |
|---|---|---|
| 只缺自动更新 | **pywebview + Sparkle** | 最小，且是本项目文档原本的备选 |
| 要小体积原生 mac app | **Tauri** | 外壳 10–15 MB + Python sidecar ≈ 50 MB |
| 真要 Windows/Linux 且渲染一致 | **Electron** | ≈ 200 MB，三套工具链，且需先重做 Keychain |

**建议顺序：Sparkle > Tauri > Electron。**

Electron 排末位不是因为技术差，而是——其核心优势（跨平台一致性）在当前策略下用不上，其核心代价（体积、工具链）却要全额支付。

### 与本文档主线的关系

Rust / GPUI / Electron 三个方案，**没有任何一个**能解决本文档第 1–5 刀列出的问题：

- `/api/returns` 的 23 秒（根因是 `indent=2` + 循环内的 `ensure_history_symbols`）
- 9 个页面信息架构分散
- HTML 内嵌在 Python f-string 里难以修改

换外壳与换语言均属**分发层**的决策，与上述**应用层**问题正交。建议先完成第 1 刀（约 1 小时），再回头评估分发层。
