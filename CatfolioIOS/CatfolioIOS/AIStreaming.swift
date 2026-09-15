import Foundation

/// A piece of an answer as the model writes it.
///
/// Two kinds, because a reasoning model writes twice: first a summary of
/// what it is thinking, then the answer. Both arrive as deltas — the text
/// since the previous event — and are shown as they come.
enum AIStreamEvent: Sendable, Equatable {
    case reasoning(String)
    case text(String)
}

/// Reading the providers' server-sent events, one `data:` line at a time.
enum AIStreamParsing {
    /// A line of the Codex Responses stream.
    ///
    /// - Parameter summaryIndex: the reasoning summary part last seen. A new
    ///   part starts a new paragraph of the thinking.
    /// - Throws: when the stream reports that the response failed.
    static func codexEvents(_ line: String, summaryIndex: inout Int?) throws -> [AIStreamEvent] {
        guard let event = payload(line) else { return [] }
        switch event["type"] as? String {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.text(delta)]
        case "response.reasoning_summary_text.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            let index = event["summary_index"] as? Int ?? 0
            defer { summaryIndex = index }
            if let summaryIndex, summaryIndex != index { return [.reasoning("\n\n"), .reasoning(delta)] }
            return [.reasoning(delta)]
        case "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any])
            throw LocalServiceError.remote((error?["message"] as? String) ?? (event["message"] as? String)
                ?? L10n.text("Codex 分析请求失败"))
        default:
            return []
        }
    }

    /// A line of a chat-completions stream (DeepSeek, OpenRouter). Reasoning
    /// models send their thinking before `content` — DeepSeek as
    /// `reasoning_content`, OpenRouter as `reasoning`.
    static func chatCompletionEvents(_ line: String) -> [AIStreamEvent] {
        guard let event = payload(line),
              let delta = (event["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { return [] }
        var events: [AIStreamEvent] = []
        let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
        if let reasoning, !reasoning.isEmpty { events.append(.reasoning(reasoning)) }
        if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
        return events
    }

    /// The message of an error sent inside a chat-completions stream.
    /// OpenRouter reports a failure that happens after the response has
    /// started this way, with the status already 200.
    static func chatCompletionError(_ line: String) -> String? {
        guard let event = payload(line), let error = event["error"] as? [String: Any] else { return nil }
        return (error["message"] as? String) ?? L10n.text("AI 请求失败")
    }

    /// Whether a line ends a chat-completions stream.
    static func isDone(_ line: String) -> Bool {
        line.hasPrefix("data:") && line.dropFirst(5).trimmingCharacters(in: .whitespaces) == "[DONE]"
    }

    private static func payload(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard body != "[DONE]", let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// The typewriter's pace. Text arrives in bursts; shown as it arrives it
/// jumps a line at a time and then stalls. Revealed at a steady rate
/// instead — faster the further behind it is, so it neither stutters nor
/// trails the model by more than a few frames. The same idea as the AI
/// SDK's `smoothStream`, measured in characters per frame.
enum SmoothReveal {
    /// About 30 frames a second.
    static let frame: Duration = .milliseconds(33)

    /// Characters to reveal this frame, with `backlog` still hidden.
    static func step(backlog: Int) -> Int {
        guard backlog > 0 else { return 0 }
        return min(backlog, max(2, backlog / 8))
    }
}

/// Markdown that is still being written, made safe to render: an unclosed
/// `**`, backtick or code fence is closed for display, so half an emphasis
/// never shows its asterisks and half a code block never swallows the page.
/// The same repair Streamdown makes on the web.
enum StreamingMarkdown {
    static func displayable(_ partial: String) -> String {
        var text = partial
        let fences = text.components(separatedBy: "```").count - 1
        if fences % 2 == 1 { return text + "\n```" }
        // A lone trailing asterisk is the first half of `**`.
        if text.hasSuffix("*"), !text.hasSuffix("**") { text.removeLast() }
        if text.components(separatedBy: "**").count % 2 == 0 { text += "**" }
        let ticks = text.replacingOccurrences(of: "```", with: "").filter { $0 == "`" }.count
        if ticks % 2 == 1 { text += "`" }
        return text
    }
}

/// Set once, from any thread: whether a stream has shown anything yet. A
/// failing provider may hand over to the next only while it has not.
final class StreamStartFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    var value: Bool { lock.withLock { started } }
    func set() { lock.withLock { started = true } }
}
