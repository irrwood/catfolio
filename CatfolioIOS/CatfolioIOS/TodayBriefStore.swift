import Foundation
import Observation

/// Computed prose stays live in the view. Only sourced AI additions are cached.
@MainActor @Observable
final class TodayBriefStore {
    struct Paragraph: Identifiable {
        let id = UUID()
        let target: String?
        var text: String
        var sources: [TodayBriefSource] = []
        var isGenerating = false
        var failure: String?
        var updatedAt = Date()
    }
    @MainActor @Observable final class Entry {
        var paragraphs: [Paragraph] = []
        var details: [String: Paragraph] = [:]
        var failure: String?
        var isGenerating = false
        var attempted = false
        var updatedAt: Date?
    }
    struct Request: Sendable {
        let context: TodayBriefContext
        let target: String?
        let previous: String
        var force = false
    }
    struct Output: Sendable {
        let text: String
        let sources: [TodayBriefSource]
        var searchFailure: String? = nil
    }
    typealias Generate = @Sendable (Request, @escaping @Sendable (String) async -> Void) async throws -> Output
    static let shared = TodayBriefStore()
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let generate: Generate
    @ObservationIgnored private let prefetchLimit: Int

    init(prefetchLimit: Int = 2, generate: @escaping Generate = { try await TodayBriefResearch.fetch($0, emit: $1) }) {
        self.generate = generate
        self.prefetchLimit = max(0, min(prefetchLimit, 2))
    }

    func entry(for context: TodayBriefContext) -> Entry {
        if let saved = entries[context.briefKey] { return saved }
        if entries.count >= 12, let old = entries.keys.first(where: { key in
            !tasks.keys.contains(where: { $0 == key || $0.hasPrefix(key + "||detail:") })
        }) { entries.removeValue(forKey: old) }
        let entry = Entry()
        entries[context.briefKey] = entry
        return entry
    }

    func start(_ context: TodayBriefContext, force: Bool = false) {
        let entry = entry(for: context)
        let key = context.briefKey
        guard !context.quotedStocks.isEmpty, tasks[key] == nil else { return }
        if !force, entry.attempted, entry.updatedAt.map({ Date().timeIntervalSince($0) < 900 }) ?? true { return }
        entry.attempted = true
        entry.isGenerating = true
        entry.failure = nil
        tasks[key] = Task {
            defer { entry.isGenerating = false; entry.updatedAt = Date(); tasks[key] = nil }
            do {
                // Keep the complete factual overview visible while gathering evidence.
                // Partial model text is not published before its sources are validated.
                let output = try await generate(.init(context: context, target: nil, previous: "", force: force)) { _ in }
                try Task.checkCancellation()
                let paragraph = Self.paragraph(output, target: nil)
                entry.paragraphs = paragraph.text.isEmpty ? [] : [paragraph]
                entry.failure = output.searchFailure
                if !paragraph.text.isEmpty {
                    for stock in context.researchStocks().prefix(prefetchLimit) {
                        expand(context, target: "stock:" + stock.ticker)
                    }
                }
            } catch {
                entry.failure = context.isChinese ? "重试市场解读" : "Retry market analysis"
            }
        }
    }

    /// Article generation has its own task per target. Opening a topic never
    /// waits for the overview, and repeated taps reuse a prepared article.
    func expand(_ context: TodayBriefContext, target: String, force: Bool = false) {
        guard context.targets.contains(target) else { return }
        let entry = entry(for: context)
        let key = context.briefKey + "||detail:" + target
        guard tasks[key] == nil else { return }
        if !force, let saved = entry.details[target], Date().timeIntervalSince(saved.updatedAt) < 900 { return }
        let old = entry.details[target]
        entry.details[target] = Paragraph(target: target, text: old?.text ?? "", sources: old?.sources ?? [], isGenerating: true)
        tasks[key] = Task {
            defer { tasks[key] = nil }
            do {
                let previous = entry.paragraphs.map(\.text).joined(separator: "\n")
                let output = try await generate(.init(context: context, target: target, previous: previous, force: force)) { _ in }
                try Task.checkCancellation()
                entry.details[target] = Self.paragraph(output, target: target)
            } catch {
                entry.details[target] = Paragraph(target: target, text: old?.text ?? "", sources: old?.sources ?? [],
                    failure: context.isChinese ? "重试详细分析" : "Retry detailed analysis")
            }
        }
    }

    private static func paragraph(_ output: Output, target: String?) -> Paragraph {
        let sources = TodayBriefEditorial.sources(output.sources)
        // Account arithmetic is always visible separately; an uncited AI news
        // paragraph must never displace it or be presented as verified research.
        let text = sources.isEmpty ? "" : TodayBriefEditorial.clean(output.text)
        return Paragraph(target: target, text: text, sources: text.isEmpty ? [] : sources, failure: output.searchFailure)
    }
}

enum TodayBriefEditorial {
    static func sources(_ sources: [TodayBriefSource]) -> [TodayBriefSource] {
        sources.reduce(into: []) { result, source in
            guard ["https", "http"].contains(source.url.scheme?.lowercased() ?? ""),
                  source.url.host != nil, source.url.user == nil, source.url.password == nil,
                  !result.contains(where: { $0.url == source.url }) else { return }
            result.append(source)
        }
    }

    /// Defense for older prompts/providers: suppress empty-news boilerplate
    /// even if a model ignores the editorial instruction. Preserve other sentences.
    static func clean(_ text: String) -> String {
        let filler = ["未找到关联证据", "没有关联证据", "未找到明确", "暂未找到", "暂无可核实", "没有可核实",
            "未发现相关", "未找到相关", "没有公开催化", "暂无公开催化", "尚无明确", "无明确公开", "没有明确公开",
            "尚未找到", "没有足够证据", "未检索到相关", "未见明确催化", "未发现明确", "no clear catalyst", "no clear public catalyst", "no verified", "no relevant news",
            "no relevant evidence", "no evidence found", "no significant news", "no material news", "no substantive news"]
        // Some providers confuse citation brackets with interactive stock links.
        // Keep source numbers readable without disturbing [[target|label]].
        let normalized = text.replacingOccurrences(of: #"\[\[(\d+)\]\]"#, with: "[$1]", options: .regularExpression)
        let separated = normalized.replacingOccurrences(of: #"(?<=[.!?])\s+(?=[A-Z])"#, with: "\n", options: .regularExpression)
        return separated.components(separatedBy: "\n").compactMap { line -> String? in
            let pattern = #"[^。！？!?；;]+[。！？!?；;]?"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let sentences = regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match -> String? in
                guard let range = Range(match.range, in: line) else { return nil }
                let sentence = String(line[range])
                return filler.contains(where: { sentence.lowercased().contains($0) })
                    || contradictsHalfComparison(sentence) ? nil : sentence
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return sentences.isEmpty ? nil : sentences
        }.joined(separator: "\n\n")
    }

    /// Source articles can contain incorrect numerical comparisons. Do not rely
    /// on an editing model to catch a checkable same-unit arithmetic error.
    private static func contradictsHalfComparison(_ sentence: String) -> Bool {
        guard sentence.contains("一半"),
              let comparison = sentence.range(of: "不到|不足|不及|低于|少于|超过|高于|多于", options: .regularExpression),
              let half = sentence.range(of: "一半", range: comparison.upperBound..<sentence.endIndex) else { return false }
        let pattern = #"([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s*(万|亿)?\s*(部|台|股|美元|港元|元|人|辆|吨)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        func quantities(_ text: String) -> [(Double, String)] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let number = Range(match.range(at: 1), in: text), let unit = Range(match.range(at: 3), in: text),
                      let value = Double(text[number].replacingOccurrences(of: ",", with: "")) else { return nil }
                let scale = Range(match.range(at: 2), in: text).map { String(text[$0]) }
                return (value * (scale == "亿" ? 100_000_000 : scale == "万" ? 10_000 : 1), String(text[unit]))
            }
        }
        guard let left = quantities(String(sentence[..<comparison.lowerBound])).last,
              let right = quantities(String(sentence[comparison.upperBound..<half.lowerBound])).first,
              left.1 == right.1, right.0 > 0 else { return false }
        let saysLess = ["不到", "不足", "不及", "低于", "少于"].contains(String(sentence[comparison]))
        return saysLess ? left.0 >= right.0 / 2 : left.0 <= right.0 / 2
    }
}
