# Archived code

Pages removed from the app but kept for reference. This folder is outside the
app target, so nothing here is compiled.

- `UnderwaterAnalysisChart.swift` — the 水下分析 page (removed 2026-09-24). Its
  three drawdown tiles moved to 亏损分析 as `DrawdownStatistics`; its model
  (`UnderwaterSeries`, `UnderwaterStack`) stays in `UnderwaterAnalysis.swift`.
  `ChartPageScrollToTop` moved to its own file.
- 回撤水下曲线 was an entry in the Performance list drawing
  `ReturnsAnalyticsView(.drawdown)`; that view and its data are unchanged, only
  the entry was removed from `ReturnsChartDestination`.
- 实验 · 等距热力图 stays in `CatfolioIOS/IsometricHeatmapLab.swift` because the
  Performance heatmap header shares its drawing types; only the Settings entry
  was removed.
