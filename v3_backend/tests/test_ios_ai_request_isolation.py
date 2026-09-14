"""Execute AIView's production request/switch methods against delayed replies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


def method(source, name):
    start = source.index("    private func " + name + "(")
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func", "func", 1)


class AIRequestIsolationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
    def test_late_answers_and_errors_cannot_cross_conversations(self):
        source = (ROOT / "AIView.swift").read_text()
        methods = "\n".join(method(source, name) for name in (
            "sendQuestion", "cancelPendingAnswer", "startNewConversation",
            "openConversation", "deleteConversation", "clearConversation",
        ))
        harness = r'''
import Foundation
struct ChatMessage {
    enum Role { case user, assistant }
    var id = UUID(); var role: Role; var text: String
}
struct Report { var markdownFallback = "report"; var contextSummary = "context" }
struct AIConversation {
    var id = UUID(); var messages: [ChatMessage] = []; var attentionReports: [UUID: Report] = [:]
}
struct LocalChatLibrary {
    var conversations: [AIConversation]; var activeID: UUID?
    var sortedByRecency: [AIConversation] { conversations }
}
enum FakeAIContent {
    static let attentionReport = Report()
    static func answer(to question: String) -> String { question }
}
enum Failure: Error { case unavailable }
@MainActor final class Provider {
    var isFakeDataMode = false; var isPublicInvestorMode = false
    var pending: [String: CheckedContinuation<String, Error>] = [:]
    func askAI(_ question: String, attentionContext: String?) async throws -> String {
        // Deliberately ignores cancellation: the view must reject late delivery.
        try await withCheckedThrowingContinuation { pending[question] = $0 }
    }
    func portfolioAttention() async throws -> Report {
        _ = try await askAI("attention", attentionContext: nil)
        return Report()
    }
}
@MainActor final class ViewState {
    var model = Provider()
    var question = ""; var errorMessage: String?
    var messages: [ChatMessage] = []; var isSending = false
    var answerGeneration = UUID(); var answerTask: Task<Void, Never>?
    var activeConversationID: UUID? = UUID(); var lastAttentionContext: String?
    var attentionReports: [UUID: Report] = [:]; var conversations: [AIConversation] = []
    static func isAttentionPreset(_ question: String) -> Bool { question == "attention" }
    func persistMessages() async {}
    func persistLibrary() async {}
    func foldActiveConversationIntoLibrary() {
        guard let id = activeConversationID else { return }
        conversations.removeAll { $0.id == id }
        conversations.append(AIConversation(id: id, messages: messages, attentionReports: attentionReports))
    }
''' + methods + r'''
}
@main struct Tests {
    @MainActor static func pending(_ name: String, in view: ViewState) async {
        let deadline = Date().addingTimeInterval(2)
        while view.model.pending[name] == nil && Date() < deadline { await Task.yield() }
        precondition(view.model.pending[name] != nil, "request did not start")
    }
    @MainActor static func main() async {
        let view = ViewState()
        view.sendQuestion("first")
        await pending("first", in: view)
        let first = view.answerTask!
        view.startNewConversation()
        view.sendQuestion("second")
        await pending("second", in: view)
        let second = view.answerTask!
        view.model.pending.removeValue(forKey: "first")!.resume(returning: "WRONG CONVERSATION")
        await first.value
        precondition(view.messages.map(\.text) == ["second"])
        precondition(view.isSending, "old request cleared the new request's busy state")
        view.model.pending.removeValue(forKey: "second")!.resume(returning: "correct answer")
        await second.value
        precondition(view.messages.map(\.text) == ["second", "correct answer"])
        precondition(!view.isSending)

        for action in 0...3 {
            let view = ViewState()
            let other = AIConversation(messages: [ChatMessage(role: .user, text: "saved")])
            view.conversations = [other]
            view.sendQuestion(action == 3 ? "attention" : "question")
            let name = action == 3 ? "attention" : "question"
            await pending(name, in: view)
            let task = view.answerTask!
            switch action {
            case 0: view.openConversation(other.id)
            case 1: view.deleteConversation(view.activeConversationID!)
            default: view.clearConversation()
            }
            let expected = view.messages.map(\.text)
            if action == 0 { view.model.pending.removeValue(forKey: name)!.resume(throwing: Failure.unavailable) }
            else { view.model.pending.removeValue(forKey: name)!.resume(returning: "late answer") }
            await task.value
            precondition(view.messages.map(\.text) == expected)
            precondition(view.attentionReports.isEmpty)
            precondition(view.errorMessage == nil)
            precondition(!view.isSending)
        }
        print("New, switch, delete, clear, late failure, report, and overlapping requests passed")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="catfolio-ai-isolation-") as folder:
            fixture = Path(folder) / "AIIsolation.swift"
            fixture.write_text(harness)
            executable = Path(folder) / "checks"
            compiled = subprocess.run(["swiftc", "-parse-as-library", str(fixture), "-o", str(executable)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
