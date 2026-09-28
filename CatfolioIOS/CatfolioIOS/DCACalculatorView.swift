import SwiftUI

struct DCACalculatorView: View {
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.locale) private var appLocale
  @State private var store = DCAStore()
  @State private var selectedDate: Date?
  @State private var focusedSeries: String?
  @State private var showsMethod = false
  @State private var showsAmount = false
  @State private var amountDraft = DCASettings()
  @State private var showsSymbols = false
  @State private var showsAIConditions = false
  @State private var showsStrategyPresets = false
  // Market research does not inherit a portfolio's demo-account mode.
  private var demo: Bool {
    #if DEBUG
      return LaunchArguments.contains("--dca-demo")
    #else
      return false
    #endif
  }
  private var loadKey: String {
    "\(store.settings.normalizedSymbol)|\(demo)|\(DayDateCodec.string(from: store.settings.start))"
  }
  private var showsCustomStrategy: Bool {
    store.settings.conditionPlan?.hasEffect == true
      && store.result?.settings.conditionPlan?.hasEffect == true
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          chartCard.id("dca-chart")
          if store.isStale {
            Text(L10n.text("参数已修改，图表与结果保留上次回测，运行后更新")).font(.footnote).foregroundStyle(.secondary)
          }
          settingsCard.id("dca-settings")
          if let error = store.error {
            Text(L10n.message(error)).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier(
              "dca.error")
            Button(L10n.text("重新加载行情")) { Task { await store.load(demo: demo) } }.buttonStyle(
              .bordered)
          }
          backtestControls.id("dca-backtest")
          if let result = store.result {
            resultCard(result).id("dca-results")
          }
          if let result = store.result {
            ForEach(result.warnings, id: \.self) {
              Text($0).font(.footnote).foregroundStyle(.secondary)
            }
          }
          Button(L10n.text("计算口径与规则说明")) { showsMethod = true }
            .font(.footnote).foregroundStyle(.secondary)
          dataSourceFooter
        }
        .padding(SettingsTemplate.pageInset)
        .padding(.bottom, 24)
      }
      #if DEBUG
        .onChange(of: store.result?.final.day) { _, day in
          if day != nil, LaunchArguments.contains("--show-dca-settings") {
            proxy.scrollTo("dca-settings", anchor: .top)
          } else if day != nil, LaunchArguments.contains("--show-dca-backtest") {
            proxy.scrollTo("dca-backtest", anchor: .top)
          } else if day != nil, LaunchArguments.contains("--show-dca-chart") {
            proxy.scrollTo("dca-chart", anchor: .top)

          } else if day != nil, LaunchArguments.contains("--show-dca-results") {
            proxy.scrollTo("dca-results", anchor: .top)
          }
        }
      #endif
    }
    .background(SettingsTemplate.pageBackground)
    .navigationTitle(L10n.text("定投计算器"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(SettingsTemplate.pageBackground, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarColorScheme(colorScheme, for: .navigationBar)
    .scrollDismissesKeyboard(.interactively)
    .appSheet(isPresented: $showsAmount) { amountSheet }
    .appSheet(isPresented: $showsSymbols) {
      DCASecurityPicker(selectedSymbol: store.settings.normalizedSymbol) { symbol in
        selectedDate = nil
        store.settings.symbol = symbol
        showsSymbols = false
      }
    }
    .appSheet(isPresented: $showsMethod) { methodSheet }
    .appSheet(isPresented: $showsStrategyPresets) { strategyPresetsSheet }
    .appSheet(isPresented: $showsAIConditions) {
      DCAAIConditionsView(plan: store.settings.conditionPlan) {
        store.settings.conditionPlan = $0
      }
    }
    .task(id: loadKey) {
      #if DEBUG
        if LaunchArguments.contains("--show-dca-fixed") { focusedSeries = "fixed" }
      #endif
      await store.load(demo: demo)
      #if DEBUG
        if LaunchArguments.contains("--show-dca-ai-conditions") { showsAIConditions = true }
        if LaunchArguments.contains("--show-dca-presets") { showsStrategyPresets = true }
        if LaunchArguments.contains("--show-dca-symbols") { showsSymbols = true }
        if LaunchArguments.contains("--show-dca-amount") { amountDraft = store.settings; showsAmount = true }
      #endif
    }
    .onChange(of: store.settings) { _, _ in store.save() }
    .onChange(of: focusedSeries) { _, _ in selectedDate = nil }
    .onChange(of: showsCustomStrategy) { _, visible in
      if !visible && focusedSeries == "strategy" { focusedSeries = nil }
      if !visible && focusedSeries == "fixedCapital" { focusedSeries = "capital" }
    }
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    SettingsCard {
      VStack(alignment: .leading, spacing: 18, content: content).padding(20).frame(
        maxWidth: .infinity, alignment: .leading)
    }
  }
  private func heading(_ title: String, caption: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.headline)
      if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
    }
  }
  private func money(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
  }
  private func pct(_ value: Double?) -> String {
    value.map { ($0 * 100).formatted(.number.precision(.fractionLength(2))) + "%" } ?? "—"
  }

  private var symbolButton: some View {
    Button {
      showsSymbols = true
    } label: {
      HStack(spacing: 12) {
        Text(store.settings.normalizedSymbol).font(.subheadline.weight(.semibold))
        Image(systemName: "chevron.down").font(.caption2)
      }.padding(.horizontal, 24).frame(minHeight: 44)
        .background(SettingsTemplate.card, in: Capsule())
    }.buttonStyle(.plain).accessibilityLabel(L10n.text("选择标的"))
      .accessibilityIdentifier("dca.symbol")
  }
  private func controlLabel(_ title: String, systemImage: String? = nil) -> some View {
    HStack(spacing: 8) {
      if let systemImage { Image(systemName: systemImage) }
      Text(title)
    }.font(.subheadline).frame(maxWidth: .infinity, minHeight: 48)
      .background(SettingsTemplate.card, in: Capsule()).contentShape(Capsule())
  }
  private var settingsCard: some View {
    @Bindable var store = store
    return VStack(spacing: 12) {
      Button {
        amountDraft = store.settings
        showsAmount = true
      } label: {
        controlLabel(L10n.text("定投金额 \(money(store.settings.baseAmount))"))
      }
      .buttonStyle(.plain).accessibilityIdentifier("dca.amount")
      Menu {
        Picker(L10n.text("定投频率"), selection: $store.settings.frequency) {
          ForEach(DCAFrequency.allCases) { Text($0.title).tag($0) }
        }
      } label: {
        controlLabel(store.settings.frequency.title, systemImage: "repeat")
      }
      .tint(.primary).accessibilityIdentifier("dca.frequency")
      Button { showsStrategyPresets = true } label: {
        controlLabel(L10n.text("策略示例"), systemImage: "list.bullet.rectangle")
      }.buttonStyle(.plain).accessibilityIdentifier("dca.presets")
      Button { showsAIConditions = true } label: {
        controlLabel(L10n.text("策略条件"), systemImage: "text.bubble")
      }.buttonStyle(.plain).accessibilityIdentifier("dca.conditions")
      if let plan = store.settings.conditionPlan, plan.hasEffect {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(plan.rules.filter(\.enabled)) { rule in
            Text(rule.displayText).appText(.caption)
          }
          Text(plan.fallbackMultiplier.map { L10n.text("其余投入基础金额的 \($0.formatted())×") }
            ?? L10n.text("其余按固定金额投入"))
            .appText(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
      }
    }
  }
  private var backtestControls: some View {
    VStack(alignment: .leading, spacing: 14) {
      heading(L10n.text("回测"))
      dateFields
      if let error = store.settings.validationError {
        Text(L10n.message(error)).font(.caption).foregroundStyle(.secondary)
      }
      runButton
    }.padding(.top, 10)
  }
  private var strategyPresetsSheet: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(DCAStrategyPreset.allCases) { preset in
            Button {
              store.settings.conditionPlan = preset.plan
              showsStrategyPresets = false
            } label: {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                  Text(preset.title).font(.headline).foregroundStyle(.primary)
                  Text(preset.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if preset.matches(store.settings.conditionPlan) {
                  Image(systemName: "checkmark").foregroundStyle(.primary)
                }
              }.padding(.vertical, 6)
            }
            .accessibilityIdentifier("dca.preset.\(preset.id)")
          }
        } footer: {
          Text(L10n.text("选择后替换当前策略条件，保留标的、基础金额、频率和日期。可继续编辑条件，再运行回测。"))
        }
        Section {
          Text(L10n.text("加投示例需要更多资金；不足 252 个交易日时暂停本期买入。"))
          Text(L10n.text("当前仅支持单一标的，不模拟多资产配置、再平衡或分红再投资。"))
        }
      }
      .navigationTitle(L10n.text("策略示例"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) {
        AppModalDoneButton { showsStrategyPresets = false }
      } }
    }
  }
  private var amountSheet: some View {
    NavigationStack {
      Form {
        Section(L10n.text("基础投入金额")) {
          Text(money(amountDraft.baseAmount)).font(.largeTitle.bold()).monospacedDigit()
          Slider(
            value: $amountDraft.baseAmount, in: 50...max(2000, amountDraft.baseAmount), step: 50
          )
          .accessibilityLabel(L10n.text("基础投入金额"))
        }
      }.tint(.primary).appPageBackground().navigationTitle(L10n.text("定投金额")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(L10n.text("取消")) { showsAmount = false }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.text("应用配置")) {
              store.settings.baseAmount = amountDraft.baseAmount
              showsAmount = false
            }.disabled(amountDraft.validationError != nil)
          }
        }
    }.presentationDetents([.medium, .large])
  }
  private var runButton: some View {
    Button {
      Task { await store.run() }
    } label: {
      HStack {
        if store.isRunning { ProgressView().tint(colorScheme == .dark ? .black : .white) }
        Text(L10n.text(store.isRunning ? "正在回测…" : "开始回测"))
      }.foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.primary).disabled(
      !store.canRun
    )
    .accessibilityIdentifier("dca.run")
  }
  private var dateFields: some View {
    @Bindable var store = store
    return HStack(spacing: 12) {
      dateField(L10n.text("起始日期"), selection: $store.settings.start, id: "dca.start-date")
      dateField(L10n.text("结束日期"), selection: $store.settings.end, id: "dca.end-date")
    }
  }
  private func dateField(_ title: String, selection: Binding<Date>, id: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      DatePicker(title, selection: selection, in: ...Date(), displayedComponents: .date)
        .datePickerStyle(.compact)
        .labelsHidden()
        .tint(.primary)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 12))
  }
  private func resultCard(_ result: DCAResult) -> some View {
    return VStack(alignment: .leading, spacing: 14) {
      heading(showsCustomStrategy ? L10n.text("回测对比") : L10n.text("回测结果"))
      card {
        if showsCustomStrategy {
          Text(L10n.text("按各自实际投入计算"))
            .appText(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("dca.comparison-basis")
        }
        HStack(spacing: 10) {
          Text(L10n.text("指标")).appText(.caption).foregroundStyle(.secondary).frame(
            width: 72, alignment: .leading)
          if showsCustomStrategy {
            comparisonHeading(L10n.text("自定义策略"), color: CatfolioPalette.securityPriceLine)
          }
          comparisonHeading(L10n.text("固定定投"), color: CatfolioTheme.services)
        }
        Divider()
        comparisonRow(
          L10n.text("累计投入"), strategy: money(result.final.contributed),
          fixed: money(result.final.baselineContributed))
        comparisonRow(
          L10n.text("期末总资产"), strategy: money(result.final.value),
          fixed: money(result.final.baseline))
        comparisonRow(
          L10n.text("期末总收益"), strategy: money(result.profit), fixed: money(result.baselineProfit))
        comparisonRow(
          L10n.text("年化收益 · XIRR"), strategy: pct(result.annualizedReturn),
          fixed: pct(result.baselineAnnualizedReturn))
        comparisonRow(
          L10n.text("投入收益率"), strategy: pct(result.final.contributed > 0 ? result.returnRatio : nil),
          fixed: pct(result.baselineReturnRatio))
        comparisonRow(
          L10n.text("净值最大回撤"), strategy: pct(result.buyCount > 0 ? result.maxDrawdown : nil),
          fixed: pct(result.baselineMaxDrawdown))
        comparisonRow(
          L10n.text("买入次数"), strategy: String(result.buyCount),
          fixed: String(result.baselineBuyCount))
        if showsCustomStrategy {
          Text(L10n.text("净值回撤剔除新增投入影响；两组仅持有同一标的，持有区间相同时回撤会相同。"))
            .appText(.micro).foregroundStyle(.secondary)
          Text(L10n.text("投入收益率 = 收益 ÷ 累计投入，不考虑投入时间；XIRR 考虑每笔投入的金额和日期。本金与投入时间可能不同，以上不是同预算的策略优劣结论。不含分红、费用与税费。"))
            .appText(.micro).foregroundStyle(.secondary)
        }
      }
    }.accessibilityIdentifier("dca.results")
  }
  private func comparisonHeading(_ title: String, color: Color) -> some View {
    VStack(alignment: .trailing, spacing: 6) {
      Capsule().fill(color).frame(width: 18, height: 3)
      Text(title).appText(.caption, weight: .semibold)
    }.frame(maxWidth: .infinity, alignment: .trailing)
  }
  private func comparisonRow(_ title: String, strategy: String, fixed: String) -> some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          Text(title).appText(.caption).foregroundStyle(.secondary)
          if showsCustomStrategy {
            HStack {
              Text(L10n.text("自定义策略"))
              Spacer()
              Text(strategy)
            }
          }
          HStack {
            Text(L10n.text("固定定投"))
            Spacer()
            Text(fixed)
          }
        }.appNumber(.callout)
      } else {
        HStack(spacing: 10) {
          Text(title).appText(.caption).foregroundStyle(.secondary).frame(
            width: 72, alignment: .leading)
          if showsCustomStrategy {
            Text(strategy).appNumber(.callout, weight: .semibold).lineLimit(1).minimumScaleFactor(0.7)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          Text(fixed).appNumber(.callout, weight: .semibold).lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }.accessibilityElement(children: .ignore)
      .accessibilityLabel(
        title + ", " + (showsCustomStrategy ? L10n.text("自定义策略") + " " + strategy + ", " : "")
          + L10n.text("固定定投") + " " + fixed)
  }
  private var chartCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        symbolButton
        Spacer()
        Text(L10n.text("回测资金走势")).font(.subheadline).foregroundStyle(.secondary)
        if store.isLoading || store.isRefreshing { ProgressView() }
      }
      if let result = store.result {
        let point =
          selectedDate.flatMap { date in
            result.curve.min(by: {
              abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            })
          } ?? result.final
        HStack {
          Text(selectedDate != nil ? point.day : chartHeadline)
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Text(
            money(
              focusedSeries == "fixedCapital" ? point.baselineContributed : focusedSeries == "capital"
                ? (showsCustomStrategy ? point.contributed : point.baselineContributed)
                : (showsCustomStrategy && focusedSeries != "fixed" ? point.value : point.baseline))
          ).appNumber(.title, weight: .semibold).lineLimit(1).minimumScaleFactor(0.7)
        }
        backtestPlot(result)
          .frame(height: SecurityPriceChartState.plotHeight)
          .padding(.leading, -SettingsTemplate.pageInset)
          .accessibilityLabel(L10n.text("长按查看每日资金"))
        ScrollView(.horizontal) {
          HStack(spacing: 16) {
            if showsCustomStrategy {
              chartKey(
                "strategy", title: L10n.text("自定义策略"), caption: L10n.text("按当前定投方式投入后的资产"),
                color: CatfolioPalette.securityPriceLine)
            }
            chartKey(
              "fixed", title: L10n.text("固定定投"), caption: L10n.text("每期买入全部基础金额"),
              color: CatfolioTheme.services, dash: [7, 4])
            chartKey(
              "capital", title: showsCustomStrategy ? L10n.text("自定义策略累计投入") : L10n.text("累计投入"), caption: showsCustomStrategy
                ? L10n.text("自定义策略每次实际买入金额的累计值") : L10n.text("累计投入"),
              color: .secondary, dash: [2, 3])
            if showsCustomStrategy {
              chartKey(
                "fixedCapital", title: L10n.text("固定定投累计投入"),
                caption: L10n.text("固定定投每次实际买入金额的累计值"),
                color: CatfolioTheme.services.opacity(0.65), dash: [5, 3])
            }
          }
        }.scrollIndicators(.hidden)
      } else {
        StandardLineChartPlaceholder(
          title: L10n.text("回测资金走势"),
          message: L10n.text("完成回测后，对比总资产与累计投入。"),
          isLoading: store.isLoading || store.isRunning,
          lineWidths: store.settings.conditionPlan?.hasEffect == true ? [2.5, 2, 1.5] : [2, 1.5],
          appearanceID: "dca|\(store.settings.normalizedSymbol)"
        )
        .frame(height: SecurityPriceChartState.plotHeight)
      }
    }.accessibilityIdentifier("dca.chart")
  }
  @ViewBuilder
  private var dataSourceFooter: some View {
    Group {
      if store.isDemo {
        Text(L10n.text("演示行情 · 合成数据"))
      } else if let result = store.result {
        Text(store.resultUsesBundledHistory
          ? L10n.text("内置 SPY · Yahoo Finance · 截至 \(result.final.day)")
          : L10n.text("Yahoo Finance 历史行情 · 截至 \(result.final.day)"))
      }
    }
    .font(.caption2).foregroundStyle(.secondary)
    .accessibilityIdentifier("dca.data-source")
  }
  /// Uses the same renderer, axes, endpoint rings, transition and hold gesture as the stock chart.
  private func backtestPlot(_ result: DCAResult) -> some View {
    let series = backtestSeries(result)
    let values = series.flatMap { $0.points.map(\.value) }
    let domain = StandardLineChartEntrancePhase.domain(values)
    let dateLabel: (Date) -> String = {
      $0.formatted(.dateTime.year().month(.abbreviated).day().locale(appLocale))
    }
    return StandardLineChart(
      series: series,
      interactionDates: result.curve.map(\.date),
      domain: domain,
      yTicks: (0..<4).map {
        domain.upperBound - (domain.upperBound - domain.lowerBound) * Double($0) / 3
      },
      axisWidth: 49,
      topInset: 15,
      bottomHeight: 0,
      leadingLineOverflow: 30,
      gridOpacity: 0.08,
      transitionKey:
        "\(focusedSeries ?? "all")|\(showsCustomStrategy)|\(result.settings.normalizedSymbol)|\(colorScheme)",
      appearanceID: "dca|\(result.settings.normalizedSymbol)",
      dataTransition: .viewportZoom,
      selectedDate: selectedDate,
      selectionIndicatorLabel: selectedDate.map(dateLabel),
      selectionSeriesIDs: Set(series.map(\.id)),
      dimsFutureDuringSelection: true,
      yAxisFont: Typography.number(.footnote),
      yAxisColor: Color.primary.opacity(0.20),
      yAxisLabel: { value in
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0)))
      },
      xAxisLabel: { _ in "" },
      onSelect: { selectedDate = $0 },
      onInteractionEnded: { _ in selectedDate = nil })
  }
  private func backtestSeries(_ result: DCAResult) -> [StandardLineChartSeries] {
    func line(
      _ id: String, _ key: KeyPath<DCACurvePoint, Double>, color: Color, width: CGFloat,
      dash: [CGFloat] = []
    ) -> StandardLineChartSeries {
      StandardLineChartSeries(
        id: id,
        points: result.curve.map {
          StandardLineChartPoint(
            id: "\(id)|\($0.day)", date: $0.date, value: $0[keyPath: key])
        },
        color: color, lineWidth: width, dash: dash, selectionRadius: 4,
        latestPointRadius: id == "strategy" ? 5 : 4,
        latestPointColor: id == "strategy"
          ? (colorScheme == .dark ? .white : .primary) : color,
        latestPointUsesGlass: false)
    }
    return [
      line("capital", showsCustomStrategy ? \.contributed : \.baselineContributed, color: .secondary, width: 1.5, dash: [2, 3]),
      line("fixedCapital", \.baselineContributed, color: CatfolioTheme.services.opacity(0.65), width: 1.5, dash: [5, 3]),
      line("strategy", \.value, color: CatfolioPalette.securityPriceLine, width: 2.5),
      line("fixed", \.baseline, color: CatfolioTheme.services, width: 2, dash: [7, 4]),
    ].filter { (showsCustomStrategy || ($0.id != "strategy" && $0.id != "fixedCapital"))
      && (focusedSeries == nil || (!showsCustomStrategy && focusedSeries == "strategy") || $0.id == focusedSeries) }
  }
  private var chartHeadline: String {
    if focusedSeries == "fixed" { return L10n.text("固定定投总资产") }
    if focusedSeries == "fixedCapital" { return L10n.text("固定定投累计投入") }
    if focusedSeries == "capital" {
      return showsCustomStrategy ? L10n.text("自定义策略累计投入") : L10n.text("累计投入")
    }
    return L10n.text("期末总资产")
  }
  private func chartKey(
    _ id: String, title: String, caption: String, color: Color, dash: [CGFloat] = []
  ) -> some View {
    Button {
      focusedSeries = focusedSeries == id ? nil : id
    } label: {
      HStack(spacing: 6) {
        Path { path in
          path.move(to: .zero)
          path.addLine(to: CGPoint(x: 18, y: 0))
        }.stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash)).frame(width: 18, height: 2)
        Text(title).appText(.caption, weight: .medium).lineLimit(1)
        if focusedSeries == id {
          Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(color)
        }
      }.fixedSize(horizontal: true, vertical: false).frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
        .opacity(focusedSeries == nil || focusedSeries == id ? 1 : 0.45)
    }.buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityHint(caption + ". " + L10n.text("点图例单独查看，再点一次显示全部"))
      .accessibilityAddTraits(focusedSeries == id ? .isSelected : [])
      .accessibilityIdentifier("dca.series.\(id)")
  }
  private var methodSheet: some View {
    NavigationStack {
      List {
        Section(L10n.text("策略条件")) {
          Text(L10n.text("从上往下采用第一条满足的规则。未命中时默认按固定金额投入，也可设置其他倍数；历史不足时暂停本期买入。"))
        }
        Section(L10n.text("资金口径")) {
          Text(
            L10n.text("固定定投每期投入并买入基础金额；自定义策略按当期倍数投入并买入。暂停时不投入、不买入；两组分别累计本金，不预存或留存现金，不主动卖出。"))
        }
        Section(L10n.text("数据与成交")) {
          Text(
            L10n.text(
              "信号只使用买入前的收盘数据，按计划日收盘价模拟买入。真实行情采用拆股复权价，没有分红再投、费用、税费或现金利息。"))
        }
        Section(L10n.text("收益口径")) {
          Text(L10n.text("收益率按各自实际投入计算；XIRR 按各自买入日期和金额计算，首次投入不足30天不年化；回撤剔除新增投入影响。历史不足不补假价格。"))
        }
      }.font(.subheadline).appPageBackground().navigationTitle(L10n.text("计算口径与规则说明")).navigationBarTitleDisplayMode(
        .inline
      )
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          AppModalDoneButton {
            showsMethod = false
          }
        }
      }
    }
  }
}

private struct DCASecurityPicker: View {
  @Environment(\.dismiss) private var dismiss
  let selectedSymbol: String
  let onSelect: (String) -> Void
  @State private var query = ""
  @State private var results: [MarketSecurityResult] = []
  @State private var searchedQuery: String?
  @State private var searchFailed = false
  private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      List {
        if searchText.isEmpty {
          if !DCAInstrumentSearch.presets.contains(selectedSymbol) {
            Section(L10n.text("当前标的")) { presetRow(selectedSymbol) }
          }
          Section {
            ForEach(DCAInstrumentSearch.presets, id: \.self) { presetRow($0) }
          } header: {
            Text(L10n.text("预设标的"))
          } footer: {
            Text(L10n.text("也可以搜索其他美股或 ETF，点选后加载历史行情。"))
          }
        } else {
          Section {
            if searchedQuery != searchText {
              ProgressView(L10n.text("正在搜索…"))
            } else if searchFailed {
              Text(L10n.text("证券目录暂时不可用，请稍后重试。"))
                .foregroundStyle(.secondary)
              Button(L10n.text("重试")) { Task { await search() } }
            } else if results.isEmpty {
              Text(L10n.text("没有找到匹配的证券")).foregroundStyle(.secondary)
              Text(L10n.text("请尝试股票代码或公司名称，当前仅支持美元计价的美股与 ETF。"))
                .appText(.caption).foregroundStyle(.secondary)
            } else {
              ForEach(results) { security in
                row(symbol: security.ticker, name: security.name, venue: security.venue)
              }
            }
          } header: { Text(L10n.text("搜索结果")) }
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .appPageBackground(SettingsTemplate.pageBackground)
      .navigationTitle(L10n.text("选择标的"))
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                  prompt: L10n.text("搜索股票、ETF 或公司名"))
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)
      .scrollDismissesKeyboard(.interactively)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.text("取消")) { dismiss() }
        }
      }
      .task(id: searchText) { await search() }
      #if DEBUG
      .onAppear {
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--dca-symbol-query"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
          query = ProcessInfo.processInfo.arguments[index + 1]
        }
      }
      #endif
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }
  private func presetRow(_ symbol: String) -> some View {
    let entry = (try? CompanyReferenceCatalog.bundled.get())?.entry(symbol: symbol, market: "US")
    return row(symbol: symbol, name: entry?.name ?? symbol, venue: entry?.exchange)
  }
  private func row(symbol: String, name: String, venue: String?) -> some View {
    Button {
      onSelect(symbol)
      dismiss()
    } label: {
      HStack(spacing: 12) {
        AssetLogo(ticker: symbol, logoSymbol: symbol, size: 36)
        VStack(alignment: .leading, spacing: 4) {
          Text(symbol).appText(.body, weight: .semibold)
          Text(ComparisonBenchmarkCatalog.names[symbol].map { L10n.label($0) }
            ?? CompanyNameCatalog.displayName(ticker: symbol, fallback: name))
            .appText(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer(minLength: 8)
        if selectedSymbol == symbol {
          Image(systemName: "checkmark").accessibilityLabel(L10n.text("已选择"))
        } else if let venue {
          Text(venue).appText(.micro).foregroundStyle(.secondary).lineLimit(1)
        }
      }.foregroundStyle(CatfolioTheme.primaryText).frame(minHeight: 48).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityIdentifier("dca.symbol.\(symbol)")
      .accessibilityAddTraits(selectedSymbol == symbol ? .isSelected : [])
  }
  private func search() async {
    let text = searchText
    guard !text.isEmpty else { results = []; searchedQuery = nil; searchFailed = false; return }
    searchedQuery = nil
    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
    let matches = await Task.detached(priority: .userInitiated) { () -> [MarketSecurityResult]? in
      guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return nil }
      return DCAInstrumentSearch.search(text, in: catalog)
    }.value
    guard !Task.isCancelled, searchText == text else { return }
    results = matches ?? []
    searchFailed = matches == nil
    searchedQuery = text
  }
}
