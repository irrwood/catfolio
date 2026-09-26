import SwiftUI
import UIKit

/// The in-app side of `SecurityDetailMeasure`, for measuring the security
/// page's open on a phone: there is no way to send taps from outside, so the
/// panel records the opens the reader makes by hand.
///
/// Reached from Settings, and only when the measurement has been turned on
/// once — the row that opens it is hidden until then, so a shipped app shows
/// nothing here.
struct SecurityDetailMeasurePanel: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var results: [SecurityDetailMeasure.Measurement] = []
    @State private var summaries: [SecurityDetailMeasure.Summary] = []
    @State private var isMeasuring = SecurityDetailMeasure.isEnabled
    @State private var usesNativeZoom = SecurityDetailNativeZoom.isEnabled
    @State private var showsShare = false
    @State private var exportURL: URL?

    private static let rowTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controls
                if summaries.isEmpty {
                    emptyState
                } else {
                    summarySection
                    rowsSection
                }
                explanation
            }
            .padding(.horizontal, HoldingDetailCardStyle.pageInset)
            .padding(.vertical, 20)
        }
        .background(CatfolioTheme.surface(for: colorScheme).ignoresSafeArea())
        .navigationTitle(L10n.text("走势转场测量"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L10n.text("刷新"))
                .accessibilityIdentifier("transition-measure-refresh")
            }
        }
        .onAppear(perform: refresh)
        // The opens happen on the tab behind this page, so the table has to be
        // re-read rather than read once: a poll keeps a run readable without
        // switching tabs, and the toolbar button forces it.
        .onDisappear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .sheet(isPresented: $showsShare) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
    }

    // MARK: Controls

    private var controls: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $isMeasuring) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("记录开合")).appText(.body)
                        Text(isMeasuring && !results.isEmpty
                             ? L10n.text("已记录 \(results.count) 次")
                             : L10n.text("打开后，每次打开个股都会记一次"))
                            .appText(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(CatfolioTheme.accent)
                .onChange(of: isMeasuring) { _, isOn in
                    UserDefaults.standard.set(isOn, forKey: SecurityDetailMeasure.preferenceKey)
                    refresh()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("转场")).appText(.body)
                    Picker(L10n.text("转场"), selection: $usesNativeZoom) {
                        Text(L10n.text("快照 A")).tag(false)
                        Text(L10n.text("原生 zoom")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: usesNativeZoom) { _, isOn in
                        SecurityDetailNativeZoom.setEnabled(isOn)
                    }
                    Text(L10n.text("切换后需要重新打开个股页才生效"))
                        .appText(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: 12) {
                    Button {
                        SecurityDetailMeasure.reset()
                        refresh()
                    } label: {
                        Text(L10n.text("重置")).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)

                    Button {
                        UIPasteboard.general.string = SecurityDetailMeasure.exportText
                        ToastCenter.shared.show(L10n.text("已复制"), kind: .info)
                    } label: {
                        Text(L10n.text("复制")).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(.black)
                    .disabled(results.isEmpty)

                    Button {
                        exportURL = writeExport()
                        showsShare = exportURL != nil
                    } label: {
                        Text(L10n.text("分享")).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(results.isEmpty)
                }
            }
            .padding(HoldingDetailCardStyle.contentInset)
        }
    }

    // MARK: Results

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("汇总")).appText(.body, weight: .medium).foregroundStyle(.secondary)
            SettingsCard {
                VStack(spacing: 0) {
                    summaryHeader
                    ForEach(summaries) { summary in
                        summaryRow(summary)
                    }
                }
            }
            Text(L10n.text("热开那一行是关键：数据全在缓存里，快照 A 仍然要为转场付固定时间。"))
                .appText(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 6) {
            summaryCell(L10n.text("转场"), width: nil, alignment: .leading)
            summaryCell(L10n.text("次数"), width: 34)
            summaryCell(L10n.text("首帧"), width: 62)
            summaryCell(L10n.text("最坏帧"), width: 62)
            summaryCell(L10n.text("≥33 / ≥66"), width: 66)
        }
        .padding(.horizontal, HoldingDetailCardStyle.contentInset)
        .padding(.vertical, 8)
        .background(CatfolioTheme.subtleFill)
    }

    private func summaryRow(_ summary: SecurityDetailMeasure.Summary) -> some View {
        HStack(spacing: 6) {
            summaryCell("\(summary.variant) · \(summary.group == "cold" ? L10n.text("冷") : L10n.text("热"))",
                        width: nil, alignment: .leading)
            summaryCell("\(summary.opens)", width: 34)
            summaryCell(String(format: "%.0f", summary.contentMs), width: 62,
                        color: summary.contentMs > 400 ? CatfolioTheme.lossDefault : nil)
            summaryCell(String(format: "%.0f", summary.worstMs), width: 62,
                        color: summary.over33 > 0 ? CatfolioTheme.lossDefault : nil)
            summaryCell("\(summary.over33) / \(summary.over66)", width: 66,
                        color: summary.over66 > 0 ? CatfolioTheme.lossDefault : nil)
        }
        .padding(.horizontal, HoldingDetailCardStyle.contentInset)
        .padding(.vertical, 10)
    }

    private var rowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("每次开合")).appText(.body, weight: .medium).foregroundStyle(.secondary)
            SettingsCard {
                VStack(spacing: 0) {
                    rowsHeader
                    ForEach(results.reversed()) { row in
                        detailRow(row)
                    }
                }
            }
        }
    }

    private var rowsHeader: some View {
        HStack(spacing: 4) {
            detailCell(L10n.text("时间"), width: 54, alignment: .leading)
            detailCell(L10n.text("结束"), width: 52, alignment: .leading)
            detailCell(L10n.text("首帧"), width: 48)
            detailCell(L10n.text("数据"), width: 48)
            detailCell(L10n.text("帧"), width: 30)
            detailCell(L10n.text("最坏"), width: 46)
            detailCell(L10n.text("超帧"), width: 46)
        }
        .padding(.horizontal, HoldingDetailCardStyle.contentInset)
        .padding(.vertical, 8)
        .background(CatfolioTheme.subtleFill)
    }

    private func detailRow(_ row: SecurityDetailMeasure.Measurement) -> some View {
        HStack(spacing: 4) {
            detailCell(Self.rowTime.string(from: row.at), width: 54, alignment: .leading)
            detailCell(row.reason, width: 52, alignment: .leading)
            detailCell(row.contentMs.map { String(format: "%.0f", $0) } ?? "—", width: 48,
                       color: (row.contentMs ?? 0) > 400 ? CatfolioTheme.lossDefault : nil)
            detailCell(row.dataMs.map { String(format: "%.0f", $0) } ?? "—", width: 48)
            detailCell("\(row.frames)", width: 30)
            detailCell(String(format: "%.0f", row.worstMs), width: 46,
                       color: row.over33 > 0 ? CatfolioTheme.lossDefault : nil)
            detailCell("\(row.over33)/\(row.over66)", width: 46,
                       color: row.over66 > 0 ? CatfolioTheme.lossDefault : nil)
        }
        .padding(.horizontal, HoldingDetailCardStyle.contentInset)
        .padding(.vertical, 8)
    }

    private func summaryCell(_ text: String, width: CGFloat?, alignment: Alignment = .trailing,
                             color: Color? = nil) -> some View {
        Text(text)
            .appNumber(.caption)
            .foregroundStyle(color ?? .primary)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    private func detailCell(_ text: String, width: CGFloat, alignment: Alignment = .trailing,
                            color: Color? = nil, weight: Font.Weight? = nil) -> some View {
        Text(text)
            .appNumber(.caption, weight: weight)
            .foregroundStyle(color ?? .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: alignment)
    }

    private var emptyState: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("还没有数据")).appText(.body)
                Text(L10n.text("打开任意个股两三次，再回到这里。第一次是冷开，之后是热开。"))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoldingDetailCardStyle.contentInset)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("怎么读")).appText(.body, weight: .medium).foregroundStyle(.secondary)
            Text(L10n.text("首帧是从点下去到页面画出第一帧；数据是到首帧带上真实行情。超帧是超过一帧预算的帧数，最坏是其中最长的一帧。真机上才量得到 GPU 成本，模拟器不算数。"))
                .appText(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Plumbing

    private func refresh() {
        results = SecurityDetailMeasure.results
        summaries = SecurityDetailMeasure.summaries
        isMeasuring = SecurityDetailMeasure.isEnabled
        usesNativeZoom = SecurityDetailNativeZoom.isEnabled
    }

    private func writeExport() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("security-detail-measure.tsv")
        do {
            try SecurityDetailMeasure.exportText.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            ToastCenter.shared.show(error.localizedDescription, kind: .error)
            return nil
        }
    }
}

/// `ShareLink` needs the file to exist up front; the panel builds it on demand,
/// so it uses the presentation directly.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
