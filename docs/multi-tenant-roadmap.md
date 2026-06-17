# Catfolio 多用户化改造路线图

更新时间：2026-06-12
目标：把当前「单用户本地工具」演进为「可多人使用的 Web 服务」。
策略：**可演进路线** —— 先把地基（阶段 0）和多租户（阶段 1）做扎实，阶段 2/3 按需要再上。
密钥模型：**用户自带 key**（每个用户在设置页填自己的 T212/DeepSeek 等 key，加密存库）。

---

## 现状诊断：为什么现在不能多人用

代码本身质量不错（模块清晰、缓存有 TTL、数据源有 fallback），但架构假设「一台机器、一个人、一个组合」。硬伤：

| # | 现状 | 位置 | 多人场景问题 |
|---|------|------|-------------|
| 1 | 完全没有认证 | `main.py` `allow_origins=["*"]`，绑 `127.0.0.1` | 谁能访问端口就能看/改全部数据 |
| 2 | 全局单一状态 | `outputs/portfolio_analysis_v2/*.json` 共享文件 | 没有「用户」概念，A 的持仓就是 B 看到的 |
| 3 | 单一全局密钥 | `data_store.secret_value()` 读 env/.env/Keychain | 所有人共用同一套 key，无法隔离 |
| 4 | 文件即数据库 | `load_json` / `write_text` | 并发写同一文件 = 数据损坏，无事务 |
| 5 | 进程内全局缓存 | `cache._store: dict` | 多 worker 缓存不一致，无法水平扩展 |
| 6 | 刷新是阻塞子进程 | `data_store.refresh_*` `subprocess.run(timeout=90)` | 同步阻塞 worker，一人刷新全站卡 |
| 7 | HTML 用 f-string 拼接 | 所有 route | 用户数据进 HTML 无转义 = XSS |
| 8 | 依赖 macOS | Keychain 走 `security` CLI、`python3` 子进程 | 上 Linux 服务器跑不起来 |
| 9 | 关闭 SSL 校验兜底 | `data_store.open_json` `_create_unverified_context` | 生产中间人风险 |
| 10 | 无测试 / 无迁移 / 无 CI，硬编码汇率 | — | 无法安全演进 |

---

## 阶段 0：地基整理（~1 周，不改功能）

让代码可演进，否则后面每步都痛。

- [ ] 清理仓库：删 `venv/`、`.venv/`、`node_modules` 软链；写好 `.gitignore`；`requirements.txt` 锁定真实依赖（当前只列 3 个，实际更多）。
- [ ] 引入配置层：`pydantic-settings` 收编 `ROOT`、FX 汇率、TTL、绑定地址，去掉硬编码。
- [ ] HTML 迁到 Jinja2 模板（自动转义堵 XSS，为前后端分离铺路）。
- [ ] pytest + GitHub Actions CI；先给 `analytics.py`、`returns_twr.py` 等纯计算逻辑补测试。
- [ ] 全局异常处理中间件 + 结构化日志，替换裸 `except Exception`。

## 阶段 1：身份与多租户（~2–3 周）—— 多人使用的核心

- [ ] 引入 Postgres + SQLAlchemy + Alembic。建模：`users`、`accounts`、`holdings`、`transactions`、`snapshots`、`api_credentials`。
- [ ] 认证用现成方案：OIDC（Google 登录）或 `fastapi-users`。每个请求带 `user_id`。
- [ ] 租户隔离：所有数据读写按 `user_id` 过滤；把全局 JSON 快照改成每用户记录。**工作量大头，触碰几乎每个 route。**
- [ ] 每用户密钥（用户自带 key）：设置页让用户填自己的 key，`cryptography` Fernet 加密存库，淘汰 Keychain 路径。
- [ ] 数据迁移脚本：把当前 JSON 持仓导入成「第一个用户」。

## 阶段 2：异步与可扩展（~2 周，按需）

- [ ] 后台任务队列（Arq/RQ/Celery）：`refresh_*` 从阻塞子进程改成异步任务，前端轮询状态。
- [ ] 缓存换 Redis；行情类数据做成全用户共享（省外部 API 调用），仅持仓按用户隔离。
- [ ] 限流（`slowapi` 或网关层），保护上游免费额度。
- [ ] build 脚本逻辑库化：从 `subprocess` 调 `scripts/*.py` 改成可 import 的函数，进任务队列跑。

## 阶段 3：生产化与商业化（按需）

- [ ] Docker 化（顺带解决 macOS 依赖），部署到 Linux/容器，HTTPS + 反代 + 健康检查。
- [ ] 合规：金融数据 + 用户 key 高敏感。传输/静态加密、审计日志、隐私政策。
- [ ] 可观测性：Sentry + Prometheus/Grafana。
- [ ] （可选）前后端分离：服务端渲染 HTML → SPA + JSON API。

---

## 关键判断

- **转折点是阶段 1**：没有用户和数据库，其它都是空中楼阁；有了它，哪怕服务 10 个人也是真正的产品。
- **别跳过阶段 0**：否则阶段 1 会在 f-string 和共享文件里挣扎。
- **最易低估**：租户隔离（改几乎每个 route）+ 密钥模型从全局改为每用户。
- 用户自带 key 的好处：隔离干净、规避上游 ToS「代多用户调用」风险；代价是用户上手门槛高，需把设置页做友好。
