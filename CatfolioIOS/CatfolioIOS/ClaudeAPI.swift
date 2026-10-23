import Foundation

/// Claude's native Messages protocol. It uses content blocks rather than
/// chat-completions choices, and keeps system instructions outside messages.
enum ClaudeAPI {
    static let apiVersion = "2026-10-21"

    static func messagesRequest(
        apiKey: String,
        model: String,
        system: String,
        user: String,
        stream: Bool
    ) throws -> URLRequest {
        var request = try authenticatedRequest(path: "messages", apiKey: apiKey, timeout: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID.isEmpty ? LocalServiceKeys.defaultClaudeModel : modelID,
            "max_tokens": 8192,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "stream": stream,
        ])
        return request
    }

    static func modelsRequest(apiKey: String) throws -> URLRequest {
        // The API defaults to 20 models. Include the largest supported page
        // so an older model saved in Settings is also available to the picker.
        try authenticatedRequest(path: "models?limit=1000", apiKey: apiKey, timeout: 20)
    }

    static func decodeMessage(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalServiceError.invalidResponse
        }
        if object["type"] as? String == "error" {
            throw LocalServiceError.remote(errorMessage(data, status: 200))
        }
        guard object["type"] as? String == "message",
              let content = object["content"] as? [[String: Any]] else {
            throw LocalServiceError.invalidResponse
        }
        try validateStopReason(object["stop_reason"] as? String)
        var pieces: [String] = []
        for block in content where block["type"] as? String == "text" {
            guard let text = block["text"] as? String else { throw LocalServiceError.invalidResponse }
            pieces.append(text)
        }
        let text = pieces.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalServiceError.invalidResponse
        }
        return text
    }

    static func errorMessage(_ data: Data, status: Int) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        if let message = error?["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        return L10n.text("Claude 请求失败（\(status)）")
    }

    /// A response cut off at the token limit is not a completed answer. In
    /// particular, it must never be accepted as a complete structured report.
    static func validateStopReason(_ reason: String?) throws {
        if reason == "max_tokens" {
            throw LocalServiceError.remote(L10n.text("Claude 回复达到长度上限，请缩短问题后重试。"))
        }
    }

    private static func authenticatedRequest(path: String, apiKey: String, timeout: TimeInterval) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LocalServiceError.missingClaudeKey }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/\(path)")!, timeoutInterval: timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
