import SwiftUI
import PhotosUI

struct ScreenshotImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismissPage
    @Environment(\.accountFlowClose) private var closeFlow
    let context: AccountConnectorContext
    var isFirstLaunchSetup = false

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsPicker = false
    @State private var imageData: Data?
    @State private var drafts: [ScreenshotHoldingDraft] = []
    @State private var nickname = ""
    @State private var newAccountID = UUID().uuidString.lowercased()
    @State private var isReading = false
    @State private var isSaving = false
    @State private var hasReadImage = false
    @State private var errorMessage: String?
    @State private var importedCount: Int?
    @State private var selectionGeneration = UUID()

    init(context: AccountConnectorContext = .create, isFirstLaunchSetup: Bool = false) {
        self.context = context
        self.isFirstLaunchSetup = isFirstLaunchSetup
    }

    private var accountID: String { context.account?.accountID ?? newAccountID }
    private var canSave: Bool {
        !isReading && !isSaving && validationMessage == nil
    }
    private var validationMessage: String? {
        do {
            _ = try ScreenshotImport.positions(drafts, accountID: accountID, accountName: nickname)
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        AccountFlowStack {
            OnboardingPage(scrollReset: hasReadImage, progress: context.isCreating ? OnboardingProgress(
                step: (hasReadImage ? 2 : 1) + (isFirstLaunchSetup ? 2 : 0),
                total: isFirstLaunchSetup ? 4 : 2) : nil) {
                OnboardingHeader(
                    title: L10n.text(importedCount != nil ? "导入完成" : "截图导入"),
                    subtitle: importedCount != nil ? nil : L10n.text("选择持仓截图，核对后即可加入。"))
                if let importedCount {
                    SettingsCard {
                        SettingsRowContainer {
                            Label(L10n.text("已导入 \(importedCount) 个持仓"), systemImage: "checkmark.circle")
                                .appText(.subheading).foregroundStyle(CatfolioTheme.positive)
                        }
                    }
                } else {
                    if !hasReadImage {
                        OnboardingFeature(symbol: "photo", title: L10n.text("选择持仓截图"),
                            detail: L10n.text("自动识别股票代码、数量、每股成本和现价。"))
                        OnboardingFeature(symbol: "lock", title: L10n.text("本机识别"),
                            detail: L10n.text("图片不会上传，也不需要配置 AI。"))
                    }
                    if isReading {
                        ProgressView(L10n.text("正在识别截图…")).padding()
                    }
                    if hasReadImage {
                        SettingsCard {
                            if context.isCreating {
                                SettingsFieldRow(L10n.text("账户昵称"), text: $nickname)
                                    .autocorrectionDisabled()
                            } else {
                                SettingsValueRow(title: L10n.text("账户名称"), value: nickname, valueIsNumeric: false)
                            }
                            SettingsButtonRow(icon: .symbol("photo"), title: L10n.text("重新选择截图")) {
                                showsPicker = true
                            }
                        }
                        if let imageData, let image = UIImage(data: imageData) {
                            DisclosureGroup(L10n.text("查看原图")) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .accessibilityLabel(L10n.text("已选择的持仓截图"))
                            }
                            .appText(.callout)
                        }
                        SettingsFootnote(L10n.text("请核对识别结果；缺失项需补全。只导入股票持仓快照，不生成历史交易。"))
                        if !drafts.isEmpty {
                            SettingsSectionHeader(L10n.text("已识别 \(drafts.count) 项，请核对是否完整。"))
                        }
                        if !context.isCreating {
                            SettingsFootnote(L10n.text("同名股票更新数量和成本；截图外的持仓会保留。"))
                        }
                        if drafts.isEmpty {
                            SettingsFootnote(L10n.text("未识别到股票持仓，请换一张含列标题的清晰截图，或手动补充。"))
                        }
                        ForEach($drafts) { $draft in
                            ScreenshotHoldingEditor(draft: $draft) {
                                drafts.removeAll { $0.id == draft.id }
                            }
                        }
                        if !drafts.isEmpty, let validationMessage {
                            SettingsFootnote(validationMessage)
                        }
                        Button {
                            drafts.append(ScreenshotHoldingDraft())
                        } label: {
                            Label(L10n.text("补充一项持仓"), systemImage: "plus")
                        }
                        .appText(.callout)
                        .disabled(drafts.count >= 200)
                        SettingsFootnote(L10n.text("现价用于初始估值，导入后可刷新行情。导入前会自动备份组合。"))
                    }
                    if let errorMessage {
                        SettingsCard {
                            SettingsRowContainer { StatusNotice(text: errorMessage) }
                        }
                    }
                }
            } actions: {
                if importedCount != nil {
                    OnboardingPrimaryButton(title: L10n.text("完成")) { dismiss() }
                } else if hasReadImage {
                    OnboardingPrimaryButton(title: L10n.text("确认加入持仓"), isDisabled: !canSave,
                                            isBusy: isSaving) {
                        Task { await save() }
                    }
                    .accessibilityIdentifier("screenshot-import-confirm")
                } else {
                    OnboardingPrimaryButton(title: L10n.text("选择持仓截图"), isDisabled: isReading,
                                            isBusy: isReading) { showsPicker = true }
                        .accessibilityIdentifier("screenshot-import-select")
                }
            }
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    AppModalDoneButton { dismiss() }.disabled(isSaving)
                }
            }
            .photosPicker(isPresented: $showsPicker, selection: $selectedPhoto, matching: .images)
            .task(id: selectedPhoto) { await readPhoto() }
            .task {
                if nickname.isEmpty { nickname = context.account?.name ?? model.suggestedAccountNickname() }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .accountFlowBrand(.screenshot)
    }

    private func dismiss() {
        if let closeFlow { closeFlow() } else { dismissPage() }
    }

    private func readPhoto() async {
        guard let selectedPhoto else { return }
        let generation = UUID()
        selectionGeneration = generation
        isReading = true
        drafts = []
        hasReadImage = false
        imageData = nil
        errorMessage = nil
        defer { if selectionGeneration == generation { isReading = false } }
        do {
            guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else {
                throw ScreenshotImportError(message: L10n.text("无法读取图片，请重新选择截图。"))
            }
            let boxes = try await ScreenshotTextRecognizer.recognize(data)
            try Task.checkCancellation()
            guard selectionGeneration == generation else { return }
            drafts = ScreenshotImportParser.parse(boxes)
            imageData = data
            hasReadImage = true
        } catch {
            guard !Task.isCancelled, selectionGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.importScreenshot(drafts, accountID: accountID, accountName: nickname,
                                             updating: !context.isCreating)
            importedCount = drafts.count
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ScreenshotHoldingEditor: View {
    @Binding var draft: ScreenshotHoldingDraft
    let onRemove: () -> Void

    var body: some View {
        SettingsCard {
            field(L10n.text("股票代码"), text: $draft.ticker, example: "AAPL / 0700.HK / 600519.SS")
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .accessibilityIdentifier("screenshot-ticker")
            field(L10n.text("持仓数量"), text: $draft.shares)
                .keyboardType(.decimalPad).accessibilityIdentifier("screenshot-shares")
            field(L10n.text("每股成本"), text: $draft.averageCost)
                .keyboardType(.decimalPad).accessibilityIdentifier("screenshot-cost")
            field(L10n.text("每股现价"), text: $draft.price)
                .keyboardType(.decimalPad).accessibilityIdentifier("screenshot-price")
            field(L10n.text("价格币种"), text: $draft.currency, example: "USD / HKD / CNY / GBX")
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .accessibilityIdentifier("screenshot-currency")
            if let problem = draft.problem {
                SettingsRowContainer { StatusNotice(text: problem) }
            }
            SettingsButtonRow(title: L10n.text("移除此项"), showsChevron: false, action: onRemove)
        }
    }

    private func field(_ title: String, text: Binding<String>, example: String = "") -> some View {
        SettingsRowContainer {
            VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                Text(title).appText(.label).foregroundStyle(SettingsTemplate.secondaryText)
                TextField(example, text: text).appText(.subheading)
                    .accessibilityLabel(title)
            }
        }
    }
}
