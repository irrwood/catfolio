# iOS 个股页面 modal 架构审计

> 2026-09-27 更新：本文保留为历史审计记录。首页个股已统一使用原 B 路径 `SecurityDetailLiveZoom` 打开、`SecurityDetailQuickClose` 短淡出关闭；A 快照转场、原生 zoom 对照模式、动画选择及测量/测试入口已移除。下文相关开关与文件不再适用于当前版本。

范围：`HoldingDetailPage.swift`、`DesignSystem.swift`、`SecurityDetailTransition.swift`、全新的 `SecurityZoomTransition.swift`、以及 `PortfolioView` / `ResearchView` / `HoldingsHeatmapView` / `ReturnsView` 的呈现点。

结论先说：**问题不是某个 bug，而是这里有"两套呈现系统同时管一个 sheet"** —— 系统的 `.sheet` 和一套手写的窗口级转场。后面列出的每一个卡顿和 bug 都能直接落到这个结构上。

---

## 1. 结构本身：系统 sheet + 手写转场，两层状态机抢同一个东西

```swift
// PortfolioView.swift:211
.sheet(item: $selectedHolding, onDismiss: { ... }) { holding in
    HoldingDetailView(holding: holding, onClose: {
        SecurityDetailSnapshotTransition.shared.close { selectedHolding = nil }  // 手写关闭
    })
    .securityDetailSheet()               // 系统 sheet：detent / 圆角 / 背景 / 拖拽关闭
    .securityDetailSnapshotBackdrop()    // 手写 backdrop：往 container 里插 shade
    .securityDetailZoomTransition(...)   // 现在是个 no-op
}
```

`SecurityDetailTransition.swift` 的头注释写着目标是"不受系统 zoom 影响"，于是它：

- 自己抓 scroll view 的快照当"飞行卡片"，在 window 顶层做动画（`beginOpen` / `Scene` / `GroundCard`）；
- 把系统 sheet 的转场关掉（`transaction.disablesAnimations = true`）再自己演一遍；
- **按类名字符串查找并隐藏系统的 dimming view**（`hideSystemDimming`，见 §3.2）；
- 往 sheet 的 surface 上装自己的 `UIScreenEdgePanGestureRecognizer` 来做关闭手势；
- 用 `DispatchQueue.main.asyncAfter(deadline: .now() + 1.5)`、`FrameWaiter`(CADisplayLink 数帧) 来"猜"系统什么时候画完。

结果就是同一份 UI 有两个互不知道的 controller：系统 sheet 一个，`SecurityDetailSnapshotTransition.shared` 一个。

同一个页面还有 4 个不同入口，行为不一致：

| 入口 | 呈现方式 | 转场 |
| --- | --- | --- |
| `PortfolioView` | `.sheet` + 手写 backdrop | 手写快照转场（A 案） |
| `ResearchView` / `ReturnsView` (×2) | `.sheet` | 纯系统 |
| `HoldingsHeatmapView` | `.sheet` | 纯系统 |
| `PortfolioView`（`--securityDetailTransitionVariant=B`） | `fullScreenCover` via `SecurityZoomPresenter` | 第二套手写转场 |

=> 同一页在 5 条路径上表现不同，bug 只在其中某几条上出现，所以"看起来到处是 bug"。

`SecurityZoomTransition.swift`（402 行）是**第二套并行的实现**（Kolos65 风格的 live-page zoom + `UIViewControllerAnimatedTransitioning`），当前只在 `UserDefaults["securityDetail.transitionVariant"] == "B"` 时启用。它和 A 案各有一份关闭手势、各有一份 dismiss 逻辑，两边的修复不会互相传递。

---

## 2. 明确的生命周期 / 竞态 bug

### 2.1 1.5s 兜底计时器会把已经关掉的页面重新"打开"（高置信度）

```swift
// SecurityDetailTransition.swift:244 (beginOpen 完成回调里)
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reveal(generation) }
```

`reveal(_:)` 的守卫是：

```swift
guard isOpening, generation == openGeneration else { return }
```

`generation` 只区分"哪一次 open"，**不区分这次 open 是否已经被关闭**。所以：

1. 点开 → open 开始，排下 1.5s 计时器；
2. 1.5s 内关掉（快速点 ✕ / 下滑）→ `presentationDidEnd()` 被调用，清掉 `presented` / `surface` / `shade`，但 `isOpening` 是否归零取决于 `close()` 是否走了 `beginClose`：
   - 走 `close(perform:)` 且 `beginClose()` 成功 → `reveal` 已被 `isAnimating` 挡住（不会执行）；
   - 但 **系统交互式下滑** 走的是 `onDismiss` → `presentationDidEnd()`，**完全绕过 `close(perform:)`**（见 §2.2），这条路径下计时器到点仍会执行 `reveal`；
3. `reveal` 里 `card?.alpha = 0`、`overlay?.removeFromSuperview()` —— 此时 overlay 可能已经是**新一次打开**的 overlay 或已经不存在；更糟的是**完成回调里的 `actions.forEach { $0() }` 会执行**，里面是 `startLowerStages()`（`whenOpenSettles` 注册的）。

后果：页面关闭后仍然触发 `startLowerStages()` → `lowerStage` 逐级 +1 → 逐级挂载 Volume/Options/Position/Research 四批重卡，并各自发起网络请求；若新页面已打开，这些动作落在新页面上，表现为"打开后莫名又开始转圈/骨架乱闪"。

### 2.2 `interactiveDismissDisabled` 根本没设 —— 注释是错的

```swift
// SecurityDetailTransition.swift:439-441
// The sheet's own pan is left alone. ... The presenter sets
// `interactiveDismissDisabled` instead: the pull only rubber-bands.
```

全仓库搜不到任何 `interactiveDismissDisabled` 的调用（只有这行注释）。也就是说：

- sheet 的下滑关闭**仍然是活的**；
- 手写 `UIScreenEdgePanGestureRecognizer`（左缘）和系统的 sheet pan **同时**负责关闭；
- 系统那条路径会在**手势取消**时走 `SecurityDetailBackdrop.dismissBackdropIfNeeded` → `animateBackdrop(presenting:false)`，把 shade 拉到 0；如果手势被取消，`finishTransition(presenting:false, cancelled:true)` 会 `isDismissing = false` 且 `shade.alpha = 1` —— 但**如果这次是"半路松手又滑回去"**，`hitBarrier` 的状态和 `shade` 就依赖 UIKit 的 completion 是否被排队（代码里已经为"排队失败"写了兜底注释，说明作者自己遇到过）；
- 更直接的问题：**同一个关闭动作有两个执行者**。系统下滑关掉后 sheet 消失，但 `presented` / `surface` / `edgePan` 只有在 `presentationDidEnd()` 里才清；期间 `isAnimating`/`closing` 可能仍为真，下一次点开被 `guard !isAnimating, pending == nil else { return .busy }` 吞掉 → **"点了没反应"**。

### 2.3 隐藏系统 dimming view 靠类名字符串，且恢复是全量恢复

```swift
// SecurityDetailTransition.swift:450
if String(describing: type(of: view)).contains("DimmingView"), !view.isHidden {
    view.isHidden = true
    hiddenDimmingViews.append(view)
```

- 依赖 UIKit 私有视图命名（`_UIDimmingView` / `UIDimmingView`），iOS 版本一变就静默失效；
- `restoreSystemDimming()` 把**所有**收集到的 view 都 `isHidden = false`。如果这期间有**别的** presentation 也隐藏了其中一个（详情页上还能再弹 `SecurityDailyMovePaper` 全屏、`AnalystConsensusView` sheet、`OptionsOIView` sheet），恢复时会把它错误地显示出来；
- `presentationDidEnd()` 里 `restoreSystemDimming()` 先跑，`pageScrollObservation = nil` 之前的部分都正常；但如果 app 在这中间进入后台/被系统回收，`hiddenDimmingViews` 持有的是强引用数组（`[UIView]`，非 weak），并且是**单例上的可变数组**，没人清理 → 该 window 上所有 dimming view 会永久保持隐藏（关掉页面后背景不再变暗）。

### 2.4 全局单例 + 只有一条路径会清理

`SecurityDetailSnapshotTransition.shared` 持有 `surface` / `shade` / `overlay` / `presented` / `closing` / `openingHost` / `settledActions` / `hiddenDimmingViews`，而 `presentationDidEnd()` **只有 `PortfolioView` 的 `onDismiss` 会调用**。任何"sheet 没走到 onDismiss"的路径（其它 4 个入口、app 重启前台、页面被 `.id()` 重建）都会留下：

- `isAnimating == true` → 之后所有打开都被判 `.busy`；
- `overlay` 留在 window 顶层（`root.isUserInteractionEnabled = false`，所以不会挡输入，但会持续持有快照图像）；
- `openingHost: UIHostingController<AnyView>?` 强引用一份完整页面视图树。

`pageScrollObservation` 也一样：它挂在**页面的 scroll view** 上（`watchPageScroll`），只有在 `reveal` 的 completion 或 `presentationDidEnd` 里才置 nil。

### 2.5 `HoldingDetailScrollBoundary` 用 KVO 改 `contentOffset`

```swift
// HoldingDetailPage.swift:491
scrollView.observe(\.contentOffset, options: [.new]) { scrollView, _ in
    let top = -scrollView.adjustedContentInset.top
    if scrollView.contentOffset.y < top { scrollView.contentOffset.y = top }
}
```

- 在 `contentOffset` 的 KVO 回调里**同步写回** `contentOffset`，是已知会产生反馈/抖动（每次回弹尝试都触发一次通知）的写法；在减速/橡皮筋期间尤其容易表现为"顶部卡一下"；
- `removeInheritedRefreshControl()` 会从视图往上找**最近**的 `UIScrollView` 并把它锁顶。它是在 `layoutSubviews()` 里被调用的 —— 也就是**每一次布局**都做一次祖先遍历 + 可能重新注册 KVO；
- 它只按"最近的 scroll view"识别，没有校验这个 scroll view 属于详情页；`HoldingDetailInteractionTests.testBoundaryOnlyTouchesItsNearestScrollView` 只覆盖了最简单的一层情况。

### 2.6 关闭按钮在动画期间会被吞掉

```swift
// SecurityDetailTransition.swift:386
func close(perform dismiss: @escaping () -> Void) {
    guard !isAnimating else { return }   // 直接 return，不 dismiss
```

打开转场还在跑时按 ✕（或快速连按）→ 什么都不发生，手指上没有任何反馈。同类守卫还出现在 `edgePanned` 的 `.began` 和 `beginOpen`。

### 2.7 调试代码留在生产路径里

`PortfolioView.swift:185-196` 的 `--demo-security-transition` 分支每次进入页面 `Task.sleep(4s)` 后自动开合两轮，虽然包在 `#if DEBUG` 里，但它调用的是真实 `openHolding`，也就是真实转场；加上 `--show-security-detail-loading` / `--show-security-data` 三个 launch argument 分支都在 `body` 里参与布局判断（`showsInitialLoadingPlaceholder` 等），会让布局出现"只有带参数启动才重现"的差异。

---

## 3. 卡顿来源

### 3.1 每次打开都在做全屏级 snapshot（最贵的一项）

`beginOpen` 一次要：

1. `host.resizableSnapshotView(from: rect, ...)` —— 从 **scroll view** 上截整个持仓行（`snapshot(of:)`）；
2. `Self.snapshot(ofRect: rowLogo, near: marker)` —— 再截一次 logo（或者走 `AssetLogoShownImages` 取已解码图）；
3. `UIHostingController(rootView: opening())` —— **再建一整棵页面视图树**（`HoldingDetailOpeningScreen`，含骨架屏、52 个 Capsule 的 52 周骨架、图表骨架）作为飞行卡片内容；
4. `reveal` 里 `measureHeader(in:)`，`beginClose` 里再 `surface.snapshotView(afterScreenUpdates: false)` —— **整页快照**，再 `resizableSnapshotView` 截 logo。

snapshot 是 GPU 拷贝，但**创建一大批 `UIView` 并把它们插进 window 顶层**会让 CoreAnimation 在这几帧里同时提交 4~5 个满屏 layer 树（overlay + dim + card + rowSnapshot + logo + openingHost.view）。这正是"打开瞬间掉帧"的直接原因，和 `openDuration = 0.46`、`dampingRatio 0.9` 的弹簧叠加后，观感就是"顿一下再滑上来"。

### 3.2 布局期间做 400 层视图遍历（×3 处）

- `hideSystemDimming`：`while index < views.count, index < 400` 遍历 window 全树；
- `Self.pageScrollView(in:)`：同样 400 层；
- `SecurityZoomDetailController.mainScrollView(in:)`：同样 400 层（B 案）；
- `HoldingDetailScrollBoundary.removeInheritedRefreshControl()`：`layoutSubviews` 里向上遍历。

这些都是主线程同步、在转场关键帧里跑的。

### 3.3 每次打开都会重放"逐级加载"动画（复现路径：反复开同一只票）

```swift
// HoldingDetailPage.swift:118
private func startLowerStages() {
    guard lowerStage == 0, !isPreview else { return }   // lowerStage 是 @State
    for stage in 1...4 { withAnimation { lowerStage = stage }; try? await Task.sleep(for: .milliseconds(140)) }
}
```

`lowerStage` 是 `HoldingDetailContentView` 的 `@State`，**sheet 每次呈现都是一个新呈现**，`@State` 从 0 开始；而 `cachedContent`（`HoldingDetailCachedContent`）是跨呈现存活的（`APIClient.cachedHoldingDetail`，LRU 24 条）。

于是：**第二次打开同一只票，数据明明已经在手里，仍然要走 560ms 的四级骨架 → 真卡的替换序列**，并且 `showsLowerSections = lowerStage > 0 && !isPreview` 在刚到的那 560ms 里恒为 false，把已经缓存好的 Volume Profile / 52 周区间 / Options / 持仓明细 / Research 全部挡在骨架屏后面。

同一个页面里 `body` 上还挂着 `.id(model.portfolioSource)`：

```swift
// HoldingDetailPage.swift:35
HoldingDetailContentView(...).id(model.portfolioSource)
```

`portfolioSource` 一变就整棵重建（所有 `@State` 归零、`lowerStage` 重来、滚动位置丢失），而它正好在 `cachedHoldingDetail` 的缓存 key 里，是会被切账户/换数据源改动的。

### 3.4 首次打开的构建量本身很重

`showsLowerSections` 一旦为真，`OptionsOIView`、`VolumePriceChart`、`HoldingPositionDetails`、`HoldingResearchSection` **全部 eager 构造**（注释里明确说"故意不用 Lazy"——理由是避免滚动时创建带来的 hitch）。这是拿"打开时的峰值"换"滚动时的抖动"，配合 §3.3 的每次重放，等于每次打开都付这个峰值。`HoldingDetailLoadingPlaceholder` 里还有 `ForEach(0..<51)` 的 52 周骨架和 `ForEach(0..<5)` 的预测市场骨架。

### 3.5 滚动期持续跑的任务

- `OptionsOIView` 的 `refreshRevision: marketDataRevision`：下拉刷新会**重建 options 请求**（服务端期权链读取，最重的一个）；
- `.task(id: marketDataRevision)` 里 `async let` 同时打 volume + prices；
- `HoldingResearchSection` 里 analyst / earnings / prediction markets 各自独立 fetch；
- `watchPageScroll` 的 KVO 每 0.5pt 位移回调一次，`abs(new.y - old.y) > 0.5` 只是早退条件，回调本身仍在滚动期间的高频路径上。

滚动时"黏手"的观感通常来自这里，而不是图表绘制。

---

## 4. 其它设计层面的问题

1. **`SecurityDetailPresentation.cornerRadius = 50`** 是为了迁就"系统 zoom 在拖拽开始时用 ~50pt"这个观察结果。现在转场已经是手写的（`beginOpen` 里自己 `card.layer.cornerRadius`），还按系统行为反推自己的圆角，属于历史遗留的耦合。

2. **`securityDetailZoomHost` / `securityDetailZoomTransition` 已经是空实现**（`DesignSystem.swift:509-517`，`self` 直接返回），但 4 个文件还在调用它们；`SecurityDetailZoomState` 也只用来做"一次只开一个"的开关，读代码的人会以为还有 zoom host。

3. **`ShadowlessContextMenuRegion`** 在最近 scroll view 上装一个共享的 `UIContextMenuInteraction`，`contextMenuInteraction(_:configurationForMenuAtLocation:)` 里用 `regions.allObjects.last(where:)` 线性扫描所有已注册区域；预览是 `UIHostingController(rootView: region.preview())` —— 每次长按**新建**一个完整的 `HoldingDetailView(isPreview: true)` 视图树。而 `PortfolioDetailsCard` 给每一行都挂了这个 modifier（`securityDetailLogoSource` + `.holdingDetailPreview`），几十行就是几十个 region + 几十个 marker view。

4. **`HoldingDetailCachedContent` 是无上限增长的引用图**：`research: [String: HoldingResearchCachedContent]`、`optionsSnapshots: [Int: OISnapshot]`、`preparedChart`，单页缓存 24 条 × 每条的 profile/history/options/analyst/earnings/prediction，全程强引用。长时间使用后内存压力会反过来变成前台卡顿（解码、内存警告下的缓存清理）。

5. **`HoldingDetailCloseButton` 的 glass 背景**在 iOS 26 上是 `glassEffect` + `Circle().fill(.clear)`，被注释解释为"装饰在 label 内部"；但它仍然参与 `overlay(alignment:)` 的布局，`frame(48×48)` + `padding(20)`，而 header 里同时有一个 48×48 的 `closeReservation` 占位——两处硬编码尺寸必须永远保持一致，改一处就错位。

---

## 5. 建议的修法（按性价比排序）

### 第一步：删掉手写转场，换成系统 zoom transition

部署目标是 **iOS 18.0**（`project.pbxproj`），所以 `matchedTransitionSource` + `.navigationTransition(.zoom(sourceID:in:))` 是可直接用的第一方 API，它做的正是这套代码想做的事（从行 → 页面的 zoom、可交互下滑、圆角/遮盖由系统处理）：

```swift
// 呈现方
@Namespace private var zoomNamespace
...
.sheet(item: $selectedHolding, onDismiss: { ... }) { holding in
    HoldingDetailView(holding: holding, onClose: { selectedHolding = nil })
        .navigationTransition(.zoom(sourceID: holding.ticker, in: zoomNamespace))
}
// 源视图
row.matchedTransitionSource(id: holding.ticker, in: zoomNamespace)
```

此后可以整块删除：`SecurityDetailTransition.swift`（943 行）、`SecurityZoomTransition.swift`（402 行）、`SecurityDetailBackdrop`（`DesignSystem.swift:274-456`）、`hideSystemDimming` / `installEdgePan` / `FrameWaiter` / `Scene` / `CloseSession`。iOS 18 已知的限制是 `.medium` detent 下有问题，本页用的是 `.large`，不受影响（参考 [Apple 开发者论坛线程](https://developer.apple.com/forums/thread/788257)、[navigationTransition 文档](https://developer.apple.com/documentation/swiftui/view/navigationtransition%28_%3A%29)）。

注意：`SecurityZoomTransition.swift` 这套 A/B 实验里没有任何用户可见的开关（只有 `UserDefaults` 键），B 案本身也没有被任何测试或设置项引用——如果 A 案被替换，B 案应当直接删掉，不要留着并行。

### 第二步：把 modal 状态从单例搬到"每次呈现一个对象"

`SecurityDetailSnapshotTransition.shared` 的生命周期 bug（§2.4）本质是"全局状态 + 没有 owner"。改成 `@State private var presentation = SecurityDetailPresentationState()` 挂在呈现方，`onDismiss` 里 `presentation.end()`，就不会再出现"某条路径忘了清理导致以后点不开"。若短期不能删转场，至少：

- `reveal(_:)` 增加"这次 open 是否仍然 current"的判定（把 `showGeneration` 在 `presentationDidEnd()` 里也 `&+= 1`，或在 `close` 时立刻 `openGeneration &+= 1`）；
- 1.5s 兜底计时器改成 `Task` 并持有、在 `presentationDidEnd()` 里 `cancel()`；
- `hiddenDimmingViews` 改成记录 `(view, 原 isHidden 值)` 并 weak 化；
- 按注释说的真的加上 `.interactiveDismissDisabled()`，或者去掉左缘 pan，二选一。

### 第三步：修"重复打开仍重放骨架"

- `startLowerStages()` 前先看 `cachedContent` 是否已有 profile/history：有就直接 `lowerStage = 4`（不带动画）；
- 或者把 `lowerStage` 提升到 `HoldingDetailCachedContent` 里（它本来就是"跨呈现保留的详情状态"）；
- `.id(model.portfolioSource)` 至少改成只在**打开时**取一次的快照值，不要让它成为 `body` 的动态 id。

### 第四步：去掉滚动边界那套 KVO

`HoldingDetailScrollBoundary` 的职责其实是三件事：去继承的 refreshControl、锁顶、限制边界。前两件都可以用 SwiftUI 表达：

- refreshControl：它来自 `EnvironmentValues.refresh`，用 `.refreshable` 的层级控制，而不是运行时 `refreshControl = nil`；
- 锁顶：`scrollBounceBehavior(.basedOnSize)` 或 `.scrollDisabled` 的边界控制，避免在 `contentOffset` KVO 里写回。

### 第五步：补一组真正覆盖转场生命周期的测试

现在 `SecurityDetailTransition` / `SecurityZoomTransition` 没有任何测试（`HoldingDetailInteractionTests` 只测了可见性和布局，`testBoundaryOnlyTouchesItsNearestScrollView` 只测最简单的边界情况）。按 AGENTS.md，能 `import SwiftUI` 的放 `CatfolioIOSViewTests`。至少要有：

- 连续 "open → 立刻 close → 再 open" 不产生重放动作（可以用计数器验证 `startLowerStages` 被调用次数）；
- `presentationDidEnd()` 之后 `isAnimating == false`、`presented == nil`、没有窗口级 overlay 残留；
- 反复打开同一只票时，第二帧就应当出现缓存内容（不经过骨架）。

---

## 附：当前无法编译

```
error: external macro implementation type 'ObservationMacros.ObservableMacro' could not be found
       for macro 'Observable()'; swift-plugin-server produced malformed response
```

Xcode 27.0 (27A266a) 下 `swift-plugin-server` 返回异常，导致所有宏展开失败（`@Observable`、`@State`、`@Entry`），并派生出大量 `cannot find '$x' in scope` / `'self' is immutable` 的假错误。这是工具链/环境问题，不是代码问题，但意味着**这份改动目前没有被编译验证过**。修完模态框之后建议先用 `-testPlan Logic` / `-testPlan Views` 跑通再继续。
