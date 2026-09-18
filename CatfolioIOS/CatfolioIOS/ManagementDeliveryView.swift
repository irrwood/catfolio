import SwiftUI
import Observation

@MainActor @Observable
final class ManagementDeliveryStore {
    private(set) var archive: ManagementDeliveryArchive?
    private(set) var busy = false
    private(set) var progress = ""
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let files: ManagementDeliveryFiles

    init(files: ManagementDeliveryFiles = .shared) { self.files = files }

    func restore(ticker: String, quarters: Int, language: String) async {
        cancel()
        archive = nil
        error = nil
        let token = generation
        let cached = await files.load(ticker: ticker, quarters: quarters, language: language)
        guard token == generation else { return }
        archive = cached
    }

    func start(ticker: String, quarters: Int, language: String, refresh: Bool) {
        guard !busy else { return }
        let readiness = AIProviderPreference.current.readiness
        guard readiness.isReady else {
            error = readiness.message
            return
        }
        busy = true
        error = nil
        let token = UUID()
        generation = token
        let previous = archive
        task = Task { [weak self] in
            guard let self else { return }
            let update: @Sendable (String) async -> Void = { [weak self] message in
                await self?.update(message, token: token)
            }
            do {
                var downloaded: ManagementDeliveryArchive
                if !refresh, let previous { downloaded = previous }
                else {
                    downloaded = try await ManagementDeliveryClient().download(ticker: ticker, quarters: quarters,
                        key: KeychainStore.string(for: LocalServiceKeys.fmp) ?? "", progress: update)
                }
                try Task.checkCancellation()
                // First download survives interruption. A refresh keeps the last
                // completed archive until its replacement has fully succeeded.
                if previous == nil {
                    try await files.save(downloaded, language: language)
                    guard generation == token else { return }
                    archive = downloaded
                }
                downloaded.report = try await ManagementDeliveryAnalyzer().analyze(downloaded, language: language, progress: update)
                try Task.checkCancellation()
                guard generation == token else { return }
                try await files.save(downloaded, language: language)
                guard generation == token else { return }
                archive = downloaded
            } catch is CancellationError {
                // Cancellation is an intentional stop, never a failed verdict.
            } catch {
                guard generation == token else { return }
                if let known = error as? ManagementDeliveryError { self.error = known.localizedDescription }
                else if error is FMPFailure { self.error = L10n.text("请检查 FMP 密钥及电话会文字稿、财报接口权限。") }
                else { self.error = L10n.text("本地分析未完成，请重试。已有资料和结果已保留。") }
            }
            guard generation == token else { return }
            busy = false
            task = nil
        }
    }

    private func update(_ message: String, token: UUID) {
        if generation == token { progress = message }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = UUID()
        busy = false
    }

    func remove(ticker: String, quarters: Int, language: String) async {
        cancel()
        let token = generation
        do {
            try await files.remove(ticker: ticker, quarters: quarters, language: language)
            guard generation == token else { return }
            archive = nil
            error = nil
        } catch {
            guard generation == token else { return }
            self.error = L10n.text("本地资料删除失败，请重试。")
        }
    }
}

struct ManagementDeliveryCard: View {
    let ticker: String
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var expanded = false
    @State private var quarters = 4
    @State private var store = ManagementDeliveryStore()
    @State private var selectedSource: ManagementDocument?
    @State private var modelStatus = AIProviderPreference.current.readiness

    private var language: String { ContentLanguage.current }

    /// Where the transcript excerpts actually go. With Apple's model they
    /// never leave the phone; with a cloud model they are sent to it.
    private var privacyNote: String {
        switch AIProviderPreference.current {
        case .apple:
            return L10n.text("文字稿与财报在 iPhone 下载、分析和保存，资料不上传服务器。")
        case .automatic:
            return L10n.text("文字稿与财报在 iPhone 下载和保存。优先用 Apple 本地模型分析；不可用时，文字稿片段会发送给你已连接的云端 AI。")
        case .codex, .deepSeek, .openRouter:
            return L10n.text("文字稿与财报在 iPhone 下载和保存；分析时，文字稿片段会发送给你在服务商中选择的 AI。")
        }
    }
    private var cacheID: String { "\(ticker)|\(quarters)|\(locale.identifier)|\(language)" }

    var body: some View {
        HoldingDetailDisclosureCard(title: L10n.text("管理层兑现情况"),
            subtitle: L10n.text("过去的承诺，后来的结果"), isExpanded: $expanded, isLoading: store.busy) {
            VStack(alignment: .leading, spacing: 20) {
                Text(privacyNote)
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L10n.text("核对范围"), selection: $quarters) {
                    ForEach([4, 6, 8], id: \.self) { count in Text(L10n.text("最近 \(count) 季度")).tag(count) }
                }.pickerStyle(.segmented).disabled(store.busy)
                if let report = store.archive?.report {
                    ManagementDeliveryResults(report: report, documents: store.archive?.documents ?? [],
                        openSource: { selectedSource = $0 })
                } else {
                    Text(L10n.text("核对管理层在电话会中提出的明确承诺，展示原话、后续结果和证据。至少需要 4 个季度的已有文字稿及 FMP 资料权限。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let archive = store.archive {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("资料下载于 \(archive.downloadedAt.formatted(date: .abbreviated, time: .shortened))"))
                        let calls = archive.documents.filter { $0.kind == .transcript }.sorted { $0.published < $1.published }
                        if let first = calls.first, let last = calls.last {
                            Text("FY\(first.fiscalYear) \(first.period) – FY\(last.fiscalYear) \(last.period)")
                        }
                        DisclosureGroup(L10n.text("本机资料与来源")) {
                            ForEach(archive.documents) { document in
                                Button { selectedSource = document } label: {
                                    Text(document.title).font(.caption).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if !modelStatus.isReady {
                    Label(modelStatus.message, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("management-delivery-error")
                }
                if store.busy {
                    HStack {
                        ProgressView()
                        Text(store.progress).font(.caption)
                        Spacer()
                        Button(L10n.text("取消")) { store.cancel() }.frame(minHeight: 44)
                    }.accessibilityIdentifier("management-delivery-progress")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            store.start(ticker: ticker, quarters: quarters, language: language, refresh: false)
                        } label: {
                            Label(store.archive == nil ? L10n.text("下载并在本机分析") : L10n.text("用本机资料重新分析"), systemImage: "text.magnifyingglass")
                                .font(.subheadline).frame(minHeight: 44)
                        }.disabled(!modelStatus.isReady)
                        if store.archive != nil {
                            Button(L10n.text("下载最新资料并重新核对")) {
                                store.start(ticker: ticker, quarters: quarters, language: language, refresh: true)
                            }.font(.caption).frame(minHeight: 44).disabled(!modelStatus.isReady)
                            Button(L10n.text("删除此范围的本机资料")) {
                                Task { await store.remove(ticker: ticker, quarters: quarters, language: language) }
                            }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("management-delivery")
        .task(id: cacheID) { await store.restore(ticker: ticker, quarters: quarters, language: language) }
        .onChange(of: scenePhase) { _, phase in
            modelStatus = AIProviderPreference.current.readiness
            if phase == .background { store.cancel() }
        }
        .onDisappear { store.cancel() }
        .sheet(item: $selectedSource) { document in ManagementDeliverySourceView(document: document) }
    }
}

struct ManagementDeliveryResults: View {
    let report: ManagementDeliveryReport
    let documents: [ManagementDocument]
    let openSource: (ManagementDocument) -> Void
    @State private var expandedIDs: Set<String>

    init(report: ManagementDeliveryReport, documents: [ManagementDocument],
         initiallyExpanded: Set<String> = [], openSource: @escaping (ManagementDocument) -> Void) {
        self.report = report
        self.documents = documents
        self.openSource = openSource
        _expandedIDs = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(report.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(ManagementDeliveryStatus.allCases, id: \.rawValue) { status in
                    HStack {
                        Text(status.title)
                        Spacer()
                        Text("\(report.assessments.filter { $0.status == status }.count)").monospacedDigit()
                    }.font(.caption).padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            ForEach(report.assessments.reversed()) { assessment in
                Divider()
                DisclosureGroup(isExpanded: Binding(get: { expandedIDs.contains(assessment.id) }, set: { value in
                    if value { expandedIDs.insert(assessment.id) } else { expandedIDs.remove(assessment.id) }
                })) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("当时原话")).font(.caption).foregroundStyle(.secondary)
                        Text(assessment.promise.quote).font(.subheadline).textSelection(.enabled)
                        sourceButton(assessment.promise.sourceID)
                        if !assessment.promise.deadline.isEmpty {
                            Text(L10n.text("原定期限：\(assessment.promise.deadline)")).font(.caption)
                        }
                        Text(L10n.text("后来结果")).font(.caption).foregroundStyle(.secondary)
                        Text(assessment.explanation).font(.subheadline)
                        ForEach(Array(assessment.evidence.enumerated()), id: \.offset) { _, evidence in
                            Text(evidence.explanation).font(.subheadline)
                            if assessment.method != "rules" {
                                Text(evidence.quote).font(.subheadline).textSelection(.enabled)
                            }
                            sourceButton(evidence.sourceID)
                        }
                        Text(assessment.method == "rules" ? L10n.text("AI 提取目标 · 数字由规则判定") : L10n.text("设备端 AI 匹配定性证据"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(assessment.promise.title).font(.subheadline).foregroundStyle(.primary)
                        Text(assessment.status.title).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.tint(.primary)
            }
            ForEach(report.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            Text(L10n.text("分析于 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(.caption2).foregroundStyle(.tertiary)
        }.accessibilityIdentifier("management-delivery-results")
    }

    @ViewBuilder private func sourceButton(_ id: String) -> some View {
        if let document = documents.first(where: { $0.id == id }) {
            Button { openSource(document) } label: {
                Label("\(document.title) · \(document.published)", systemImage: "doc.text")
                    .font(.caption).frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
        }
    }
}

private struct ManagementDeliverySourceView: View {
    let document: ManagementDocument
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(document.title).font(.headline)
                    Text(document.published).font(.caption).foregroundStyle(.secondary)
                    Link(destination: document.url) {
                        Label(L10n.text("打开来源链接"), systemImage: "arrow.up.right.square").font(.subheadline)
                    }
                    if document.url.host == "financialmodelingprep.com" {
                        Text(L10n.text("来源接口需 FMP 权限；链接不包含密钥，下方可直接查看已下载内容。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if document.kind == .financials {
                        Text(L10n.text("以下为 FMP 标准化财报字段，原始申报口径请核对来源。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(document.text).font(.subheadline).textSelection(.enabled)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(L10n.text("来源资料"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
        }
    }
}
