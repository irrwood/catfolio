"""Execute each connector's production sync and account-scoping methods."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


def method(source, name):
    start = source.index("    private func " + name + "(")
    body = source.index("{", start)
    depth, end = 1, body + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    # Class-backed test state needs an explicit capture where the SwiftUI value does not.
    return source[start:end].replace("private func", "func", 1).replace(
        "onProgress: { seconds in", "onProgress: { [self] seconds in") + "\n"


class EmptyBrokerSyncTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
    def test_empty_authorized_accounts_reach_import_from_the_sync_button(self):
        moo = (ROOT / "MoomooOAuthView.swift").read_text()
        ibkr = (ROOT / "IBKRFlexView.swift").read_text()
        harness = r'''
import Foundation
struct Account { var accountID: String?; var source = "" }
struct Row { var accountID: String }
struct Context { var account: Account?; var isCreating = false }
struct Snapshot {
    var accounts: [Row] = []; var positions: [Row] = []; var fills: [Row] = []
    var transactions: [Row] = []; var accountCurrencies: [String: String] = [:]
    var accountNames: [String: String] = [:]; var reportDate: String?
    var historyWarnings: [String] = []; var positionAccountIDs: Set<String> = []
    var syncedPositionAccountIDs: Set<String> { positionAccountIDs.union(positions.map(\.accountID)) }
}
typealias MoomooSnapshot = Snapshot
typealias IBKRFlexSnapshot = Snapshot
struct Credentials: Equatable {}
struct ImportResult { var warnings: [String] = []; var holdingsCount = 0 }
enum Status { case idle, working(String), success(String), failure(String) }
enum L10n { static func text(_ s: String) -> String { s } }
enum DisplayCurrency { static let current = Self.gbp; case gbp; var rawValue: String { "GBP" } }
@MainActor enum Probe { static var snapshot = Snapshot(); static var imports: [Snapshot] = [] }
@MainActor struct MoomooOpenAPIClient {
    var credentialAccountID: String?
    func fetchSnapshot(reportingCurrency: String) async throws -> Snapshot { Probe.snapshot }
}
@MainActor struct IBKRFlexClient {
    func fetchOpenPositions(credentials: Credentials, onProgress: @escaping (Int) -> Void) async throws -> Snapshot { Probe.snapshot }
}
@MainActor final class Model {
    var accounts: [Account] = []
    func accountNames(source: String, accountIDs: [String], preferredNickname: String,
                      targetAccountID: String?) -> [String: String] { [:] }
    func importMoomoo(_ snapshot: Snapshot, accountNames: [String: String], replacingAccountsOnly: Bool) async throws -> ImportResult {
        precondition(replacingAccountsOnly)
        Probe.imports.append(snapshot)
        return ImportResult()
    }
    func importIBKR(_ snapshot: Snapshot, accountNames: [String: String], replacingAccountsOnly: Bool) async throws -> ImportResult {
        precondition(replacingAccountsOnly)
        Probe.imports.append(snapshot)
        return ImportResult()
    }
}
@MainActor class State {
    var isWorking = false; var status = Status.idle; var context = Context()
    var model = Model(); var nickname = "test"; var snapshot: Snapshot?
    var snapshotCredentials: Credentials?
    func credentials() throws -> Credentials { Credentials() }
    func persistCredentials(for ids: [String]) throws { precondition(!ids.isEmpty) }
    func saveCredentials(_ value: Credentials, accountIDs: Set<String>) throws { precondition(!accountIDs.isEmpty) }
}
@MainActor final class MoomooState: State {
''' + method(moo, "sync") + method(moo, "snapshotForContext") + r'''
}
@MainActor final class IBKRState: State {
''' + method(ibkr, "syncFlex") + method(ibkr, "resultAccountIDs") + method(ibkr, "snapshotForContext") + r'''
}
@main struct Tests {
    @MainActor static func main() async {
        for creating in [false, true] {
            Probe.snapshot = Snapshot(accounts: [.init(accountID: "A")], positionAccountIDs: ["A"])
            let context = Context(account: creating ? nil : Account(accountID: "A"), isCreating: creating)
            Probe.imports = []
            let moo = MoomooState(); moo.context = context
            await moo.sync()
            precondition(Probe.imports.count == 1 && Probe.imports[0].positions.isEmpty)
            precondition(Probe.imports[0].accounts.map(\.accountID) == ["A"])
            guard case .success = moo.status else { fatalError("Moomoo zero positions rejected") }
            precondition(!moo.isWorking)
            Probe.imports = []
            let ibkr = IBKRState(); ibkr.context = context
            await ibkr.syncFlex()
            precondition(Probe.imports.count == 1 && Probe.imports[0].positions.isEmpty)
            precondition(Probe.imports[0].syncedPositionAccountIDs == ["A"], "scope discarded the empty section")
            guard case .success = ibkr.status else { fatalError("IBKR zero positions rejected") }
            precondition(!ibkr.isWorking)
        }
        Probe.snapshot = Snapshot(accounts: [.init(accountID: "B")], positionAccountIDs: ["B"])
        Probe.imports = []
        let moo = MoomooState(); moo.context.account = Account(accountID: "A")
        await moo.sync()
        let ibkr = IBKRState(); ibkr.context.account = Account(accountID: "A")
        await ibkr.syncFlex()
        precondition(Probe.imports.isEmpty, "missing target account must not be imported as empty")
        print("Both connector sync buttons import valid empty accounts and reject missing target accounts")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="catfolio-empty-sync-") as folder:
            fixture = Path(folder) / "EmptySync.swift"
            fixture.write_text(harness)
            executable = Path(folder) / "checks"
            compiled = subprocess.run(["swiftc", "-parse-as-library", str(fixture), "-o", str(executable)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
