# Helm 桌面 App 改造计划（macOS）

更新时间：2026-06-12
目标：把当前「本地 Web 服务（uvicorn + 浏览器）」打包成 **可双击运行的 macOS 桌面 App**，用户无需装 Python、无需命令行。
目标平台：**仅 macOS**（所以 Keychain 走系统 `security` CLI 的现状保留，不做跨平台改造）。
密钥模型：沿用现状 —— 用户自己的 key 存在 macOS Keychain / `.env`，单用户本机使用。

---

## 为什么这条路比 SaaS 简单一个数量级

当前架构里那些「对 SaaS 是硬伤」的假设，对单用户桌面 App **恰恰是优点**：

| 维度 | 多租户 SaaS | 本地桌面 App |
|------|------------|-------------|
| 认证 / 登录 | 必须 | **不需要** |
| 数据库 + 租户隔离 | 必须，改每个 route | **不需要**，现有 JSON 文件够用 |
| 每用户密钥加密存库 | 必须 | **不需要**，macOS Keychain 正合适 |
| Redis / 任务队列 / 限流 | 需要 | 不需要 |
| 部署 / HTTPS / 运维 | 需要 | 不需要 |
| 合规 / ToS 代调用风险 | 高 | 几乎没有（用户用自己的 key 调自己账户） |

结论：保留 FastAPI 后端 + 现有 HTML 前端，**套一层桌面外壳 + 打包 Python 运行时**即可。

---

## 技术选型

- **外壳：pywebview** —— 纯 Python，用 macOS 自带 WKWebView，几乎不改前端，最快拿到能双击运行的 App。
- **打包：PyInstaller**（或 py2app）—— 把 Python 运行时一起打进 `.app`，用户无需装 Python。
- 启动流程：App 进程内用后台线程跑 uvicorn（绑 `127.0.0.1` + 随机空闲端口）→ pywebview 开窗口指向 `http://127.0.0.1:<port>` → 关窗口时优雅停掉 uvicorn。

（备选：Tauri / Electron + Python sidecar，外壳更精致、可自动更新，但要上额外工具链。等需要「正经发布 + 自动更新」时再考虑，当前不必要。）

---

## 必做的 4 件事

### 1. ⚠️ 解掉 subprocess 链（唯一的硬骨头，优先做）
打包后没有 `python3` 可执行文件、`scripts/*.py` 也不在磁盘上，所有 `subprocess.run(["python3", ...])` 都会失败。

涉及位置：
- `data_store.refresh_trading212()`（`data_store.py:434`）调 `python3 scripts/build_trading212_v2.py`
- `build_trading212_v2.py:83` 又 `run_step(["python3", enrich_trading212_data.py])`
- `scripts/build_all.py` 串了 8 个 `python3 scripts/*.py`

改造：
- [x] 把运行时 hot path 的 `build_trading212_v2.py` / `enrich_trading212_data.py` / `build_portfolio_html.py` 改成可 import 的函数；`build_trading212_v2` 暴露 `build_and_write()` 返回摘要。
- [x] `refresh_trading212()` 改成进程内调用（`build_trading212_v2.build_and_write()`），移除 `subprocess` + `python3` 依赖，返回契约（`ok`/`stdout`/`returncode`）保留。
- [x] 保留各脚本 CLI 入口（`if __name__ == "__main__"`），运行时走 import。
- [x] 端到端验证：进程内刷新跑通（133 持仓 → 118 合并，重建 HTML，~9.5s，无子进程）。
- [ ] 待办（非 hot path）：`scripts/build_all.py` 及其链上的 `analyze_portfolio.py` / `enrich_*.py` 仍是 `python3 subprocess`，仅离线手动数据准备用、App 运行时不触发；若以后要做「一键全量重建」再同样改造。

> 注：这一步无论桌面还是 SaaS 都要做，是最有复用价值的重构。

### 2. 套桌面外壳 + 打包
- [ ] 加 `desktop.py` 入口：后台线程起 uvicorn（随机端口）→ `webview.create_window("Helm", f"http://127.0.0.1:{port}")` → `webview.start()`。
- [ ] 处理生命周期：等 uvicorn 就绪再开窗口；窗口关闭触发 uvicorn shutdown。
- [ ] 写 PyInstaller spec：把 `app/static/`（含 vendor 的 echarts/lightweight-charts）、模板、`scripts/` 作为 `datas` 打进包；隐藏导入补全（uvicorn/fastapi 常需手动加 `hiddenimports`）。
- [ ] 产出 `Helm.app`，本机双击验证。

### 3. 数据目录改到 macOS 标准位置
- [ ] 当前数据写在仓库 `outputs/`（`settings.ROOT` / `V2_DIR`）。打包后仓库目录只读，必须迁出。
- [ ] 默认数据目录改为 `~/Library/Application Support/Helm/`（已有 `HELM_ROOT` 环境变量，改默认值 + 首次运行自动建目录即可）。
- [ ] 首次启动若目录为空，给空状态引导（让用户去设置页填 key、点同步）。

### 4. 静态资源 / 路径鲁棒性
- [ ] `StaticFiles(directory=APP_DIR/"static")`、模板路径等，在 PyInstaller 下 `__file__` 会变成临时解包目录 `sys._MEIPASS`。统一用一个 `resource_path()` 辅助函数解析，确保打包后能找到资源。

---

## 可选 / 后续

- [ ] **App 图标 + 菜单栏**：给 `.app` 配图标，pywebview 加最简原生菜单（关于 / 退出）。
- [ ] **代码签名 + 公证（notarization）**：不签名的话 Gatekeeper 会拦截，用户要右键打开。若要分发给他人，需 Apple Developer 账号做 codesign + notarize。自用可跳过。
- [ ] **自动更新**：自用可手动换包；要分发再考虑 Sparkle 或换 Tauri。
- [ ] **SSL 校验**：`data_store.open_json` 的 `_create_unverified_context` 兜底建议收紧或加开关（桌面环境风险低，但属良好卫生）。

---

## 建议的最小可行路径

```
解 subprocess 链  →  数据目录迁到 Application Support  →  pywebview 包一层  →  PyInstaller 出 Helm.app
```

预计 1–2 周内可得一个能双击运行、写入用户数据目录、自用无需命令行的 macOS App。代码签名/公证留到要分发给别人时再做。

---

## 与 SaaS 路线的关系

两条路线**唯一共享的重构是「解 subprocess 链」**（见上文第 1 步）。其余完全分叉：桌面 App 拥抱单用户 + 本地文件 + Keychain；SaaS 要推翻它们换成数据库 + 认证 + 租户隔离（见 `docs/multi-tenant-roadmap.md`）。先做这一步重构，两条路都不亏。
