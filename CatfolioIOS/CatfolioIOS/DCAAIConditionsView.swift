import SwiftUI

/// A local draft: generation and edits cannot mutate the active backtest.
struct DCAAIConditionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editor: DCAConditionDraftStore
    @FocusState private var focusedRuleID: String?
    let onApply: (DCAConditionPlan?) -> Void

    init(plan: DCAConditionPlan?, onApply: @escaping (DCAConditionPlan?) -> Void) {
        self.init(editor: DCAConditionDraftStore(plan: plan), onApply: onApply)
    }
    init(editor: DCAConditionDraftStore, onApply: @escaping (DCAConditionPlan?) -> Void) {
        _editor = State(initialValue: editor)
        self.onApply = onApply
    }
    var body: some View {
        @Bindable var editor = editor
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("例如：价格低于200日均线15%时投2倍；RV20高于40%时暂停，波动率条件优先。"), text: $editor.input, axis: .vertical)
                        .lineLimit(5...10).accessibilityIdentifier("dca.conditions.input")
                    HStack {
                        Text(L10n.text("\(editor.input.count) / 6000 字")).appText(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if editor.isGenerating {
                            ProgressView()
                            Button(L10n.text("取消")) { editor.cancel() }
                        } else {
                            Button { editor.generate() } label: {
                                Label(L10n.text("AI 整理"), systemImage: "sparkles")
                            }.disabled(editor.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editor.input.count > 6000)
                                .accessibilityIdentifier("dca.conditions.generate")
                        }
                    }
                    if editor.input.isEmpty {
                        Button(L10n.text("试试：低于均线时加倍")) {
                            editor.input = L10n.text("价格低于200日均线15%时投入2倍，其余按原计划。")
                        }
                    }
                } header: {
                    Text(L10n.text("用一句话描述你的策略"))
                } footer: {
                    Text(L10n.text("使用当前 AI 服务，仅发送这段描述与已有规则；不发送账户或持仓。整理后由你检查，再应用到回测。"))
                }
                if let error = editor.error {
                    Section { Text(L10n.message(error)).foregroundStyle(.secondary) }
                }
                if !editor.issues.isEmpty {
                    Section(L10n.text("还需要补充")) {
                        ForEach(Array(editor.issues.enumerated()), id: \.offset) { _, issue in
                            Label(issue, systemImage: "questionmark.circle").font(.subheadline)
                        }
                        Text(L10n.text("请在描述中补充或调整，再点 AI 整理。未解决的问题不会带入回测。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if editor.hasDraft {
                    Section {
                        if !editor.visibleSummary.isEmpty { Text(editor.visibleSummary).font(.subheadline) }
                        Text(L10n.text("从上往下，采用第一条满足的规则；倍数按基础金额计算。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        if editor.inputChanged {
                            Label(L10n.text("描述已修改，请重新整理后应用"), systemImage: "arrow.clockwise")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text(L10n.text("整理后的规则")) }
                    ForEach(editor.draft.rules) { rule in
                        let ruleBinding = editor.binding(for: rule)
                        Section {
                            Toggle(isOn: ruleBinding.enabled) {
                                Text(L10n.text("规则 \((editor.draft.rules.firstIndex(where: { $0.id == rule.id }) ?? 0) + 1)"))
                                    .font(.headline)
                            }.tint(CatfolioTheme.positive)
                            Text(rule.displayText).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            DisclosureGroup(L10n.text("调整参数")) {
                                DCAConditionRuleControls(rule: ruleBinding, focusedRuleID: $focusedRuleID)
                            }
                            HStack {
                                Button { editor.moveRule(id: rule.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(editor.draft.rules.first?.id == rule.id)
                                    .accessibilityLabel(L10n.text("提高优先级"))
                                Button { editor.moveRule(id: rule.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(editor.draft.rules.last?.id == rule.id)
                                    .accessibilityLabel(L10n.text("降低优先级"))
                                Spacer()
                                Button(L10n.text("移除"), role: .destructive) {
                                    if focusedRuleID == rule.id { focusedRuleID = nil }
                                    editor.removeRule(id: rule.id)
                                }.accessibilityIdentifier("dca.conditions.remove.\(rule.id)")
                            }.buttonStyle(.borderless).frame(minHeight: 36)
                        }.disabled(editor.isGenerating)
                    }.id(editor.ruleGeneration)
                    Section {
                        Picker(L10n.text("未命中时"), selection: $editor.draft.fallbackMultiplier) {
                            Text(L10n.text("固定定投 1×")).tag(nil as Double?)
                            ForEach(Array(Set([0, 0.5, 1, 1.5, 2, 3] + [editor.draft.fallbackMultiplier].compactMap { $0 })).sorted(), id: \.self) { value in
                                Text(value == 0 ? L10n.text("暂停本期买入") : "\(value.formatted())×").tag(Optional(value))
                            }
                        }.disabled(editor.isGenerating)
                        if let error = editor.draft.validationError { Text(L10n.message(error)).font(.footnote).foregroundStyle(.secondary) }
                    } footer: {
                        Text(L10n.text("条件只读取买入前的收盘数据；历史不足时暂停本期。每期直接投入并买入基础金额乘以所选倍数，暂停时不投入。"))
                    }
                    Section {
                        Button(L10n.text("清空条件"), role: .destructive) {
                            focusedRuleID = nil
                            editor.clear()
                        }
                    }
                }
            }
            .appPageBackground().navigationTitle(L10n.text("策略条件"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("应用到回测")) {
                        guard editor.canApply else { return }
                        onApply(editor.draft.rules.isEmpty && editor.draft.fallbackMultiplier == nil ? nil : editor.draft)
                        dismiss()
                    }.disabled(!editor.canApply).accessibilityIdentifier("dca.conditions.apply")
                }
            }
            .onChange(of: editor.input) { _, _ in editor.cancel() }
            .onDisappear { editor.cancel() }
        }
    }
}

extension DCAConditionDraftStore {
    /// A removed row may still receive reads/writes while SwiftUI dismisses
    /// its text field. Never retain an array index or resurrect a deleted row.
    func binding(for snapshot: DCAConditionRule) -> Binding<DCAConditionRule> {
        let generation = ruleGeneration
        return Binding {
            guard self.ruleGeneration == generation else { return snapshot }
            return self.draft.rules.first(where: { $0.id == snapshot.id }) ?? snapshot
        } set: { updated in
            guard self.ruleGeneration == generation, !self.isGenerating,
                  let index = self.draft.rules.firstIndex(where: { $0.id == snapshot.id }),
                  updated.id == snapshot.id else { return }
            self.draft.rules[index] = updated
        }
    }
}

private struct DCAConditionRuleControls: View {
    @Binding var rule: DCAConditionRule
    var focusedRuleID: FocusState<String?>.Binding
    var body: some View {
        if rule.conditions.count > 1 {
            Picker(L10n.text("判断方式"), selection: $rule.join) {
                ForEach(DCAJoin.allCases) { Text($0.title).tag($0) }
            }
        }
        ForEach(rule.conditions.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 10) {
                Text(rule.conditions[index].metric.title).font(.subheadline.weight(.medium))
                if rule.conditions[index].metric != .price {
                    Picker(L10n.text("观察周期"), selection: $rule.conditions[index].window) {
                        ForEach(Array(Set([5, 10, 20, 50, 100, 200, 252, rule.conditions[index].window])).sorted(), id: \.self) {
                            Text(L10n.text("\($0) 个交易日")).tag($0)
                        }
                    }
                }
                Picker(L10n.text("判断"), selection: $rule.conditions[index].comparison) {
                    ForEach(DCAConditionComparison.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Text(L10n.text("阈值"))
                    TextField(L10n.text("阈值"), value: $rule.conditions[index].threshold, format: .number)
                        .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                        .focused(focusedRuleID, equals: rule.id)
                    Text(rule.conditions[index].metric.unit).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(rule.actionText).font(.subheadline)
            Slider(value: $rule.multiplier, in: 0...3, step: 0.25)
                .accessibilityLabel(L10n.text("买入倍数"))
        }.padding(.vertical, 8)
    }
}
