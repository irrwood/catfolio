**审查证据与复现说明**

此目录只包含合成数据、算法快照、测试摘要和审查专用模拟器截图；没有复制真实券商账本或密钥。独立 Swift 脚本抽取了待审查算法，并用最小数据结构、日期/本地化等替身补齐依赖。它们证明所列算法在样例输入下的行为，不是整个 iOS App 的集成测试，也不是修复后的回归测试。

| 文件 | 内容 |
| --- | --- |
| [repros.swift](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/repros.swift) / [repros-output.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/repros-output.txt) | CRLF、拆股重建、TWR、FX 单位/账户/过期、FIFO 时间、UK 同日优先级 |
| [adapter_repros.swift](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/adapter_repros.swift) / [adapter-output.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/adapter-output.txt) | 原证券映射函数及 Moomoo 成交过滤代码的独立执行 |
| [cloud_repro.swift](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/cloud_repro.swift) / [cloud-output.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/cloud-output.txt) | 原 CloudPreferences 算法；隔离 UserDefaults suite，云端替换为空内存存储 |
| [limiter_repro.swift](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/limiter_repro.swift) / [limiter-output.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/limiter-output.txt) | 原 FMPRequestLimiter 与 5 秒退避的并发样例 |
| [csv_perf.swift](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/csv_perf.swift) / [csv-perf-output.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/csv-perf-output.txt) | 原 CSV 解析器的优化版大文件实验；不是物理 iPhone 基准 |
| [xctest-summary.json](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/xctest-summary.json) | 全量 iOS 测试的 xcresulttool 汇总 |
| [ui-recheck-summary.json](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/ui-recheck-summary.json) / [ui-recheck.log](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/ui-recheck.log) | 两个 UI 失败测试的定向重跑结果 |
| [pytest-summary.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/pytest-summary.txt) | Python iOS 检查的失败项目与总数 |
| [design-check.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/design-check.txt) / [localization-check.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/localization-check.txt) | 设计与本地化脚本输出 |
| [source-manifest.json](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/source-manifest.json) / [source-excerpts.json](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/source-excerpts.json) / [worktree-status.txt](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/worktree-status.txt) | 报告生成时源码 SHA256、引用附近源码与工作区状态；本轮 App 测试构建早于部分并发改动 |
| ios18-*.png | iPhone SE 3 / iOS 18 演示数据截图 |

在装有 Xcode Swift 工具链的 macOS 运行独立算例：

    cd '/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence'
    swift repros.swift
    swift adapter_repros.swift
    swift cloud_repro.swift
    swiftc -parse-as-library limiter_repro.swift -o /tmp/catfolio-audit-limiter
    /tmp/catfolio-audit-limiter

大文件实验应单独运行，避免把其他任务争用造成的墙钟延迟视为设备性能：

    swiftc -O csv_perf.swift -o /tmp/catfolio-audit-csv-perf
    /usr/bin/time -l /tmp/catfolio-audit-csv-perf

本轮 XCTest 命令（审查专用模拟器；清理后需要换成可用设备 UUID）：

    xcodebuild test -project CatfolioIOS/CatfolioIOS.xcodeproj -scheme CatfolioIOS \
      -destination 'platform=iOS Simulator,id=271110E9-674E-40D1-B6DA-09D5BB0AD916' \
      -derivedDataPath /tmp/catfolio-ios-audit-build \
      -resultBundlePath /tmp/catfolio-ios-audit-tests.xcresult \
      -parallel-testing-enabled NO \
      -skip-testing:CatfolioIOSTests/PublicInvestorCatalogTests/testLiveInvestorAccountTodayHistoryAndPerformance \
      -skip-testing:CatfolioIOSTests/EarningsHistoryTests/testLiveDeviceNasdaqRead \
      -skip-testing:CatfolioIOSTests/SecurityDebateResearchTests/testLiveNVDAWithConfiguredProvider \
      CODE_SIGNING_ALLOWED=NO

UI 重跑使用 test-without-building，仅选择 HoldingDetailInteractionTests/testDetailRemovesInheritedRefreshWithoutDisablingParentOrChildRefresh 和 LineChartMotionTests/testCaptureEntranceRebaseRapidSwitchAndReducedMotion。

Python 检查通过临时 venv 中的 pytest 执行；最初尝试 unittest 的输出已被正确的 pytest 结果取代，不作为报告计数依据。原始大日志与 xcresult 仍在本机 /tmp/catfolio-ios-audit*，临时目录可能被系统清理，因此将摘要和复现代码保存在本目录。
