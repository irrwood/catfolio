import Foundation
import QuartzCore

/// Where the security page's data comes from on each open, and when — to see
/// whether the placeholders are covering a real wait or data that was already
/// at hand.
///
///     --trace-security-load
///
/// Off unless launched with that argument. Every open is one JSON line in
/// `Documents/security-load-trace.jsonl`: milliseconds from the tap for each
/// step, and for each source whether it was already in memory, found in the
/// disk cache, or had to come from the network.
@MainActor
enum SecurityDetailLoadTrace {
    static let launchArgument = "--trace-security-load"
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    private final class Record {
        let ticker: String
        let started = CACurrentMediaTime()
        var marks: [(String, Double)] = []
        var facts: [String: String] = [:]
        init(ticker: String) { self.ticker = ticker }
    }

    private static var current: Record?

    /// The tap.
    static func begin(_ ticker: String) {
        guard isOn else { return }
        flush()
        current = Record(ticker: ticker)
        // Long enough for the network to answer; an open closed sooner is
        // written when it ends.
        let record = current
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if current === record { flush() }
        }
    }

    /// A step, once per open; the first time counts.
    static func mark(_ step: String) {
        guard isOn, let current, !current.marks.contains(where: { $0.0 == step }) else { return }
        current.marks.append((step, (CACurrentMediaTime() - current.started) * 1000))
    }

    /// A fact about the open — where a source was found.
    static func note(_ key: String, _ value: String) {
        guard isOn, let current, current.facts[key] == nil else { return }
        current.facts[key] = value
    }

    /// Writes the open that is in progress, if any.
    static func flush() {
        guard let record = current else { return }
        current = nil
        var object: [String: Any] = ["ticker": record.ticker]
        object["ms"] = Dictionary(uniqueKeysWithValues: record.marks.map { ($0.0, (($0.1 * 10).rounded()) / 10) })
        object["found"] = record.facts
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardError.write(Data(("[SECURITY-LOAD] " + line + "\n").utf8))
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = documents.appendingPathComponent("security-load-trace.jsonl")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
