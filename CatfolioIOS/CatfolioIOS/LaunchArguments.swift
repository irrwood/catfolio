import Foundation

/// The `--…` flags that open a page straight away or stand demo data in for a
/// screenshot, a recording or a test.
///
/// They are a development door, not a feature: in a Release build every one of
/// them answers no, so a shipped app cannot be talked into a demo branch by
/// its launch arguments. Read the flags through here rather than through
/// `ProcessInfo` — a call site that asks `ProcessInfo` directly keeps its
/// branch in the shipped binary.
enum LaunchArguments {
    #if DEBUG
    static var all: [String] { ProcessInfo.processInfo.arguments }
    #else
    static var all: [String] { [] }
    #endif

    static func contains(_ flag: String) -> Bool { all.contains(flag) }

    /// The value of a `--flag=value` argument, for the flags that name a
    /// destination or a demo dataset.
    static func value(forFlag prefix: String) -> String? {
        all.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
