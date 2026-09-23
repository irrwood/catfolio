import Foundation

/// Device-local UI preference, independent of currency and company-name display.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "catfolio.language"
    var id: String { rawValue }

    static func resolvedIdentifier(_ preference: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if let preference, let language = Self(rawValue: preference), language != .system {
            return language.rawValue
        }
        for preferred in preferredLanguages {
            let code = preferred.lowercased().split(separator: "-").first
            if code == "zh" { return "zh-Hans" }
            if code == "en" { return "en" }
        }
        return "en"
    }

    static var currentIdentifier: String {
        resolvedIdentifier(UserDefaults.standard.string(forKey: preferenceKey))
    }

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

/// Exact-key localization. Interpolated values remain data and are never translated.
enum L10n {
    static var listSeparator: String { AppLanguage.currentIdentifier == "en" ? ", " : "、" }
    static var clauseSeparator: String { AppLanguage.currentIdentifier == "en" ? "; " : "；" }

    /// App-authored sentence fragments only. Strip existing terminators to avoid doubled punctuation.
    static func sentences(_ parts: [String], language: String = AppLanguage.currentIdentifier) -> String {
        let fragments = parts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
        }.filter { !$0.isEmpty }
        guard !fragments.isEmpty else { return "" }
        return fragments.joined(separator: language == "en" ? ". " : "。")
            + (language == "en" ? "." : "。")
    }

    static var responseLanguageInstruction: String {
        ContentLanguage.current == "en"
            ? " Respond in English. Keep ticker symbols, schema keys and numeric values unchanged."
            : " 请用简体中文回答，保留股票代码、JSON 字段名和数字原值。"
    }

    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]

        init(stringLiteral value: String) {
            key = value
            arguments = []
        }

        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []

            init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }

            mutating func appendLiteral(_ literal: String) { key += literal }
            mutating func appendInterpolation<T>(_ value: T) {
                key += "%@"
                arguments.append(String(describing: value))
            }
            mutating func appendInterpolation<T: CVarArg>(_ value: T, specifier: String) {
                key += "%@"
                arguments.append(String(format: specifier, value))
            }
        }
    }

    /// Translate app-provided account nicknames without rewriting saved account names.
    /// Broker prefixes, numeric suffixes and unknown custom names retain their identity.
    static func accountName(_ name: String, language: String = AppLanguage.currentIdentifier) -> String {
        let separator = " · "
        let split = name.range(of: separator)
        let prefix = split.map { String(name[..<$0.upperBound]) } ?? ""
        let nickname = split.map { String(name[$0.upperBound...]) } ?? name
        let exact = render(Message(stringLiteral: nickname), language: language)
        if exact != nickname { return prefix + exact }
        if let space = nickname.lastIndex(of: " ") {
            let number = nickname[nickname.index(after: space)...]
            let base = String(nickname[..<space])
            if !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) {
                let translated = render(Message(stringLiteral: base), language: language)
                if translated != base { return prefix + translated + " " + number }
            }
        }
        return name
    }

    /// For a known UI key or enum display label only; do not pass user-entered text.
    static func label(_ key: String) -> String {
        text(Message(stringLiteral: key))
    }

    static func text(_ message: Message) -> String {
        render(message, language: ContentLanguage.current)
    }

    /// Render an app-authored status/error retained in a data cache. Match only
    /// complete catalog messages; never use this for names, news or AI answers.
    /// Captured values remain verbatim, just like `text` interpolation.
    static func message(_ value: String, language: String = ContentLanguage.current) -> String {
        let target = storedMessages.catalogs[language] ?? storedMessages.catalogs["en"] ?? [:]
        if let exact = target[value] { return exact }
        if let key = storedMessages.exactKeys[value], let exact = target[key] { return exact }
        for rule in storedMessages.rules where value.contains(rule.anchor) {
            let range = NSRange(value.startIndex..., in: value)
            guard let match = rule.expression.firstMatch(in: value, range: range),
                  let template = target[rule.key] else { continue }
            let parts = template.components(separatedBy: "%@")
            guard parts.count == match.numberOfRanges else { continue }
            var result = parts[0]
            for index in 1..<match.numberOfRanges {
                guard let capture = Range(match.range(at: index), in: value) else { return value }
                result += String(value[capture]) + parts[index]
            }
            return result
        }
        // These prefixes are also stable routing markers in cached return
        // warnings. Translate their presentation without rewriting that data.
        for key in ["每日 TWR ", "现金流镜像：", "MWR：", "TWR：", "账户历史："] {
            for prefix in Set([key, storedMessages.catalogs["en"]?[key] ?? key])
                where value.hasPrefix(prefix) && value.count > prefix.count {
                return (target[key] ?? prefix) + message(String(value.dropFirst(prefix.count)), language: language)
            }
        }
        if value.contains("\n") {
            return value.components(separatedBy: "\n").map { message($0, language: language) }.joined(separator: "\n")
        }
        return value
    }

    private struct StoredMessageCatalog {
        struct Rule {
            let key: String
            let anchor: String
            let expression: NSRegularExpression
        }
        var catalogs: [String: [String: String]] = [:]
        var exactKeys: [String: String] = [:]
        var rules: [Rule] = []

        init() {
            for language in ["en", "zh-Hans"] {
                guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let catalog = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String] else { continue }
                catalogs[language] = catalog
            }
            var candidates: [String: Set<String>] = [:]
            for key in (catalogs["en"] ?? [:]).keys.sorted() {
                for template in Set([key, catalogs["en"]?[key] ?? key, catalogs["zh-Hans"]?[key] ?? key]) {
                    let parts = template.components(separatedBy: "%@")
                    if parts.count == 1 {
                        candidates[template, default: []].insert(key)
                    } else if let anchor = parts.max(by: { $0.count < $1.count }), anchor.count >= 2,
                              parts.joined().count >= 6 || ["今日 %@", "成交量 %@×", "%@ 日均线"].contains(key) {
                        // A substantial literal anchor avoids treating generic
                        // formats such as "%@ %@" as arbitrary text templates.
                        let pattern = "\\A" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "\\z"
                        if let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                            rules.append(Rule(key: key, anchor: anchor, expression: expression))
                        }
                    }
                }
            }
            for (text, keys) in candidates where keys.count == 1 { exactKeys[text] = keys.first }
            rules.sort { $0.anchor.count == $1.anchor.count ? $0.key < $1.key : $0.anchor.count > $1.anchor.count }
        }
    }

    private static let storedMessages = StoredMessageCatalog()

    static func render(_ message: Message, language: String, bundle: Bundle = .main) -> String {
        let resource = bundle.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? bundle
        let template = resource.localizedString(forKey: message.key, value: message.key, table: nil)
        // Substitute only catalog placeholders, never values containing '%' or other keys.
        // Avoid printf so literal financial percentages require no escaping.
        let parts = template.components(separatedBy: "%@")
        guard parts.count == message.arguments.count + 1 else { return template }
        var result = parts[0]
        for (index, argument) in message.arguments.enumerated() {
            result += argument + parts[index + 1]
        }
        return result
    }
}

/// Capture once at the start of a content job; child tasks inherit the selection.
enum ContentLanguage {
    @TaskLocal static var requested: String?
    static var current: String { requested ?? AppLanguage.currentIdentifier }
    static func cacheKey(_ key: String, language: String) -> String { "\(language)|\(key)" }
    static func newsURL(ticker: String, name: String, language: String) -> URL {
        let chinese = language.hasPrefix("zh")
        return newsURL(query: "\(ticker) \(name) " + (chinese ? "股票" : "stock analyst"), language: language)
    }
    static func newsURL(query: String, language: String) -> URL {
        let chinese = language.hasPrefix("zh")
        var url = URLComponents(string: "https://news.google.com/rss/search")!
        url.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: chinese ? "zh-CN" : "en-US"),
            URLQueryItem(name: "gl", value: chinese ? "CN" : "US"),
            URLQueryItem(name: "ceid", value: chinese ? "CN:zh-Hans" : "US:en")
        ]
        return url.url!
    }
    static func acceptsHeadline(_ title: String, language: String) -> Bool {
        let hasHan = title.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
        return language.hasPrefix("zh") ? hasHan : !hasHan
    }
}
