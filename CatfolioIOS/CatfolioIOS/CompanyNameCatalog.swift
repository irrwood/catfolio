import ImageIO
import Observation
import SwiftUI
import UIKit

enum CompanyNameCatalog {
    static func displayName(ticker: String, fallback: String, mode: CompanyNameDisplay = .current) -> String {
        let ticker = ticker.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let conciseName = commonNames[ticker] ?? removingLegalSuffixes(fallback)
        guard mode == .chineseShort else { return conciseName.isEmpty ? ticker : conciseName }
        if let name = chineseShortNames[ticker] { return name }

        let suffixes = [".L", ".SW", ".AS", ".DE", ".PA", ".MI", ".HK", ".TO"]
        if let suffix = suffixes.first(where: ticker.hasSuffix) {
            let baseTicker = String(ticker.dropLast(suffix.count))
            if let name = chineseShortNames[baseTicker] { return name }
        }

        return conciseName.isEmpty ? ticker : conciseName
    }

    // Display aliases only: the source name and security identifier remain intact.
    // Match exact listings; stripping arbitrary exchange suffixes can alias another company.
    private static let commonNames: [String: String] = [
        "AAPL": "Apple", "ADBE": "Adobe", "AMD": "AMD", "AMZN": "Amazon",
        "ARM": "Arm", "ASML": "ASML", "AVGO": "Broadcom", "AXP": "American Express", "BABA": "Alibaba",
        "BAC": "Bank of America", "BIDU": "Baidu", "BRK-A": "Berkshire Hathaway",
        "BRK-B": "Berkshire Hathaway", "BRK.A": "Berkshire Hathaway", "BRK.B": "Berkshire Hathaway",
        "COST": "Costco", "CSCO": "Cisco", "CVX": "Chevron", "DIS": "Disney",
        "GOOG": "Alphabet", "GOOGL": "Alphabet", "GS": "Goldman Sachs", "IBM": "IBM", "IBKR": "Interactive Brokers",
        "INTC": "Intel", "JD": "JD.com", "JNJ": "Johnson & Johnson", "JPM": "JPMorgan Chase",
        "KO": "Coca-Cola", "LLY": "Eli Lilly", "MA": "Mastercard", "MCD": "McDonald’s",
        "META": "Meta", "MS": "Morgan Stanley", "MSFT": "Microsoft", "MU": "Micron",
        "NFLX": "Netflix", "NKE": "Nike", "NVDA": "NVIDIA", "ORCL": "Oracle",
        "PEP": "PepsiCo", "PFE": "Pfizer", "PLTR": "Palantir", "QCOM": "Qualcomm",
        "SBUX": "Starbucks", "TSLA": "Tesla", "TSM": "TSMC", "UBER": "Uber",
        "UNH": "UnitedHealth", "V": "Visa", "WMT": "Walmart", "XOM": "ExxonMobil"
    ]

    private static let legalSuffix = try! NSRegularExpression(
        pattern: #"[\s,]+(?:incorporated|corporation|limited|holdings?|inc|corp|ltd|plc|co)\.?$"#,
        options: [.caseInsensitive]
    )
    private static let stockDescriptor = try! NSRegularExpression(
        pattern: #"\s+(?:-\s+)?(?:common stock|common shares|ordinary shares)$"#,
        options: [.caseInsensitive]
    )
    private static let fundDescriptor = try! NSRegularExpression(
        pattern: #"\b(?:ETF|ETN|UCITS|fund|trust)\b"#, options: [.caseInsensitive]
    )

    private static func removingLegalSuffixes(_ source: String) -> String {
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        // Fund names carry product, share-class and distribution information.
        guard fundDescriptor.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)) == nil else { return original }
        let parts = SecurityNameParts(original)
        let classSuffix = String(original.dropFirst(parts.primary.count))
        var name = parts.primary
        if let match = stockDescriptor.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let range = Range(match.range, in: name) {
            name = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let match = legalSuffix.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range, in: name) {
            let shortened = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shortened.isEmpty else { break }
            name = shortened
        }
        return name + classSuffix
    }

    // Only include established everyday names. An unknown symbol keeps the broker name
    // instead of receiving an unreliable machine-translated corporate name.
    private static let chineseShortNames: [String: String] = [
        "AAPL": "苹果",
        "ABBV": "艾伯维",
        "ADBE": "奥多比",
        "AMD": "超威半导体",
        "AMZN": "亚马逊",
        "ARM": "Arm",
        "ASML": "阿斯麦",
        "ASMLA": "阿斯麦",
        "AVGO": "博通",
        "BABA": "阿里巴巴",
        "BAC": "美国银行",
        "BIDU": "百度",
        "BMO": "蒙特利尔银行",
        "BMY": "百时美施贵宝",
        "BRK-B": "伯克希尔",
        "BRK.B": "伯克希尔",
        "CSCO": "思科",
        "COST": "好市多",
        "CVX": "雪佛龙",
        "DIA": "道琼斯30",
        "DIS": "迪士尼",
        "EQQQ": "纳斯达克100",
        "GLD": "黄金ETF",
        "GOOG": "谷歌",
        "GOOGL": "谷歌",
        "GS": "高盛",
        "IBM": "IBM",
        "INTC": "英特尔",
        "IUSA": "iShares 标普500",
        "IWM": "罗素2000",
        "JD": "京东",
        "JNJ": "强生",
        "JPM": "摩根大通",
        "KO": "可口可乐",
        "LLY": "礼来",
        "LI": "理想汽车",
        "MA": "万事达",
        "MCD": "麦当劳",
        "META": "Meta",
        "MRK": "默沙东",
        "MS": "摩根士丹利",
        "MSFT": "微软",
        "MU": "美光",
        "NFLX": "奈飞",
        "NIO": "蔚来",
        "NKE": "耐克",
        "NTDOY": "任天堂",
        "NVDA": "英伟达",
        "ORCL": "甲骨文",
        "PDD": "拼多多",
        "PEP": "百事",
        "PFE": "辉瑞",
        "PLTR": "帕兰提尔",
        "QCOM": "高通",
        "QQQ": "纳斯达克100",
        "RR": "劳斯莱斯",
        "SBUX": "星巴克",
        "SPY": "SPDR 标普500",
        "TD": "多伦多道明银行",
        "TCEHY": "腾讯",
        "TSLA": "特斯拉",
        "TSM": "台积电",
        "UBER": "优步",
        "UNH": "联合健康",
        "V": "Visa",
        "VEU": "美国以外市场",
        "VHVG": "Vanguard 发达市场",
        "VOO": "Vanguard 标普500",
        "VUSA": "Vanguard 标普500",
        "VUAG": "Vanguard 标普500",
        "VTI": "美国全市场",
        "VWCE": "Vanguard 全球市场",
        "VWRL": "Vanguard 全球市场",
        "VWRP": "Vanguard 全球市场",
        "WMT": "沃尔玛",
        "XPEV": "小鹏汽车"
    ]
}
