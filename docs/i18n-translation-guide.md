# Catfolio 翻译工作手册（i18n 增量翻译）

> 给接手翻译的 AI / 协作者。读完即可独立工作，无需其它上下文。
> 任务：把 Catfolio 的 UI 文案从中文翻译成英文，做法是往**一个字典**里加词条。

---

## 0. 一句话原理

每个页面渲染成 HTML 后，`wrap_v4_layout()` 会对**整页 HTML** 调用一次
`t_block(html, "en")`：它把页面里出现的每个字典 key（中文）替换成对应的英文 value。
**不在字典里的中文，原样保留（显示中文）。** 所以你的全部工作 = 把每页残留的中文补进字典。

- 字典在 `v3_backend/app/i18n.py` 的 `EN = { ... }`。
- 替换按 key 长度**从长到短**自动进行（代码已 `sorted(..., reverse=True)`），长句优先，避免短词破坏长句。
- **你只改 `app/i18n.py` 这一个文件。** 不要动任何路由、HTML、JS、逻辑。

---

## 1. 不要翻译的东西（重要，翻错会改坏数据/代码）

- ❌ 用户数据：回测名称、股票代码、公司名（这些是运行时动态数据，本来就不该进字典）。
- ❌ 策略编辑器里的 Python 代码和代码里的中文注释（那是用户代码）。
- ❌ Python 源码里的 `#` 注释（不渲染给用户）。
- ❌ 已经是英文的（如 `Portfolio Lab`、`Catfolio`、`CAGR`、ticker）。
- ✅ 只翻**用户在界面上看得到的文案**：标题、按钮、标签、下拉项、表头、占位符、状态提示等。

---

## 2. 标准流程（每个页面重复一遍）

### 第 1 步：起服务
```bash
cd v3_backend
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8799 &
```

### 第 2 步：抓出该页「切英文后仍残留的中文」
直接请求英文版页面（带 cookie `catfolio_lang=en`），提取 HTML 里剩下的中文 —— 这些**正是**还没翻译的 UI 文案（已翻的会显示成英文）：

```bash
# <path> 换成页面路由，如 / 或 /lab 或 /settings
curl -s --cookie "catfolio_lang=en" "http://127.0.0.1:8799/<path>" > /tmp/page.html

# 提取残留中文短语（用 Python，跨平台可靠）：
python3 - <<'PY'
import re
html = open("/tmp/page.html", encoding="utf-8").read()
# 抓出含中文的「文本片段」：中文及其相邻的非标签字符
frags = re.findall(r'[^<>{}"\n]*[一-鿿][^<>{}"\n]*', html)
seen = set()
for f in frags:
    f = f.strip()
    if f and f not in seen:
        seen.add(f)
        print(repr(f))
PY
```

> 说明：这是**渲染后的最终 HTML**，包含 JS 字符串字面量里的中文（如状态提示 `"正在加载…"`）——这些也要翻，因为 `t_block` 同样会替换 JS 源码里的字面量。

### 第 3 步：判断哪些要翻
对每条残留中文：
- 在标签文本、`placeholder=`/`title=` 属性、JS 的 `.textContent=`/字符串里 → **翻**。
- 是用户数据（回测名、公司名）或代码注释 → **跳过**。

### 第 4 步：加进字典
打开 `v3_backend/app/i18n.py`，在 `EN = {` 里**按页面分段**追加：
```python
    # ── home / dashboard ──
    "数据与控制中心": "Data & Control Center",
    "管理您的个人投资组合数据源。...": "Manage your personal portfolio data sources. ...",
```
**关键规则：**
- key 必须和源码里的中文**逐字符一致**——含全角标点（，。：（）、）、空格、占位符。
  最稳的做法：从第 2 步的 `repr()` 输出或源码里**复制粘贴**中文，不要手敲。
- 一个中文字符串在多个页面出现也只需加一条（全局生效）。

### 第 5 步：验证
```bash
.venv/bin/python3 -m py_compile app/i18n.py          # 语法检查
# 重启服务后，重跑第 2 步，确认该页残留中文显著减少
```
**完工标准**：切到 EN 后该页 `curl + 提取中文` 的结果只剩「用户数据 / 代码注释」，UI 文案全英文。

---

## 3. 两个坑

1. **子串冲突**：若某短词是某长句的子串，而长句没进字典，替换短词会把长句里那段也改掉。
   对策：**优先翻译完整的句子/词组**，别拆成碎片词。长句进了字典就安全（按长度降序替换）。

2. **动态拼接字符串**：如 JS 里 `"基准(" + symbol + ") 总收益"`。
   对策：把能独立成立的片段（`"基准("`、`") 总收益"`）各作为一条 key 翻译；或在源码里找到完整字面量再翻。

---

## 4. 页面清单 / 进度

| 页面 | 路由文件 | 路由 | 中文行数(约) | 状态 |
|---|---|---|---|---|
| 全局框架（导航/侧栏/状态） | `app/components.py` | 所有页面共用 | 26 | ✅ 已完成 |
| 策略回测 | `app/routes/strategy.py` | `/strategy` | 75 | ✅ 已完成（参考样例） |
| 数据控制台 | `app/routes/home.py` | `/` | 78 | ⬜ 待翻 |
| Portfolio Lab | `app/routes/lab.py` | `/lab` | 95 | ⬜ 待翻 |
| 持仓热力图 | `app/routes/heatmap.py` | `/heatmap` | 94 | ⬜ 待翻 |
| 回测与优化 | `app/routes/backtest.py` | `/backtest` | 90 | ⬜ 待翻 |
| AI 分析 | `app/routes/ai.py` | `/ai` | 65 | ⬜ 待翻 |
| 系统设置 | `app/routes/settings.py` | `/settings` | 63 | ⬜ 待翻 |
| 收益对比 | `app/routes/returns.py` | `/returns` | 49 | ⬜ 待翻 |
| 审计报表 | （由 `scripts/build_portfolio_html.py` 生成） | `/report` | — | ⬜ 待翻（方法相同） |

> 审计报表的内容来自生成器脚本产出的 HTML、经 `app/routes/report.py` 后处理。`t_block` 同样作用于其最终页面，所以**把报表里的中文加进 `EN` 字典即可**，流程完全一致。

建议顺序：按「中文行数从少到多」或「用户最常看」来，比如 `/settings` → `/returns` → `/ai` → `/home` → `/backtest` → `/heatmap` → `/lab` → `/report`。每页独立提交一次，便于 review。

---

## 5. 已完成部分可作模板

`app/i18n.py` 里 `EN` 字典已有「chrome」和「strategy lab」两段，照着它的风格和分段注释继续加即可。`app/routes/strategy.py` 是一个「已完全翻译的页面」的参考——对照它能看出哪些字符串需要进字典。

## 6. 验证整体收尾

全部页面翻完后，逐页执行第 2 步的提取脚本，确认所有页面切 EN 后无 UI 中文残留；再 `git diff app/i18n.py` 检查只动了字典。完成。
