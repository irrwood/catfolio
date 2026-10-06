import SwiftUI

struct MarkdownMessageText: View {
    @Environment(\.locale) private var appLocale
    let markdown: String

    var body: some View {
        let blocks = MarkdownRenderCache.blocks(of: markdown)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(CatfolioStyle.blue)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inlineText(text)
                .currencyFont(.body)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            inlineText(text)
                .currencyFont(headingStyle(for: level), weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.body.weight(.bold))
                        inlineText(item)
                            .currencyFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .appNumber(.subheading, weight: .semibold)
                            .foregroundStyle(.secondary)
                        inlineText(item)
                            .currencyFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .currencyFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .code(language, code):
            VStack(alignment: .leading, spacing: 7) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inlineText(cell)
                                .currencyFont(.caption1, weight: .semibold)
                                .frame(minWidth: 88, alignment: .leading)
                        }
                    }

                    Divider()

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineText(cell)
                                    .currencyFont(.caption1)
                                    .frame(minWidth: 88, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .divider:
            Divider()
        }
    }

    private func inlineText(_ source: String) -> Text {
        Text(MarkdownRenderCache.inline(source))
    }

    private func headingStyle(for level: Int) -> UIFont.TextStyle {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, code: String)
    case table(header: [String], rows: [[String]])
    case divider
}

/// Parsed markdown, kept between renders.
///
/// Both halves of rendering a message used to run inside `body`: the block
/// split, and an `AttributedString(markdown:)` for every paragraph, heading
/// and list item. SwiftUI evaluates `body` whenever anything the view depends
/// on changes, so a conversation re-parsed every visible message on every
/// state change — including the one the scroll observer writes as the list
/// moves. The assistant's replies are long, `AttributedString(markdown:)` is
/// the expensive half, and the cost arrived as text that took seconds to
/// appear and buttons that answered late.
///
/// The text of a message never changes once it is on screen, so the parse is
/// pure and its result can simply be kept. Keyed by the source string: two
/// bubbles with the same text are the same parse.
enum MarkdownRenderCache {
    private final class Blocks { let value: [MarkdownBlock]; init(_ v: [MarkdownBlock]) { value = v } }
    private final class Inline { let value: AttributedString; init(_ v: AttributedString) { value = v } }

    // Bounded, because a long conversation would otherwise hold every string
    // it ever rendered. NSCache also evicts under memory pressure on its own.
    private static let blockCache: NSCache<NSString, Blocks> = {
        let cache = NSCache<NSString, Blocks>()
        cache.countLimit = 400
        return cache
    }()

    private static let inlineCache: NSCache<NSString, Inline> = {
        let cache = NSCache<NSString, Inline>()
        cache.countLimit = 2000
        return cache
    }()

    static func blocks(of source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let parsed = MarkdownBlockParser.parse(source)
        blockCache.setObject(Blocks(parsed), forKey: key)
        return parsed
    }

    static func inline(_ source: String) -> AttributedString {
        let key = source as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        inlineCache.setObject(Inline(parsed), forKey: key)
        return parsed
    }
}

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let rawLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(
                    language: rawLanguage.isEmpty ? nil : rawLanguage,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let header = tableCells(from: line),
               isTableSeparator(lines[index + 1], expectedColumns: header.count) {
                flushParagraph()
                index += 2
                var rows: [[String]] = []
                while index < lines.count,
                      let row = tableCells(from: lines[index]),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(normalized(row, count: header.count))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = orderedItem(from: trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    quoteLines.append(String(quoteLine.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count),
              line.dropFirst(marks.count).first == " " else { return nil }
        return (
            marks.count,
            String(line.dropFirst(marks.count + 1)).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func unorderedItem(from line: String) -> String? {
        guard line.count > 2 else { return nil }
        let prefixes = ["- ", "* ", "+ "]
        guard let prefix = prefixes.first(where: line.hasPrefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func orderedItem(from line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot != line.startIndex else { return nil }
        let number = line[..<dot]
        let afterDot = line.index(after: dot)
        guard number.allSatisfy(\.isNumber),
              afterDot < line.endIndex,
              line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func tableCells(from line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableSeparator(_ line: String, expectedColumns: Int) -> Bool {
        guard let cells = tableCells(from: line), cells.count == expectedColumns else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let hyphens = trimmed.filter { $0 == "-" }.count
            return hyphens >= 3 && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func normalized(_ row: [String], count: Int) -> [String] {
        if row.count == count { return row }
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }
}
