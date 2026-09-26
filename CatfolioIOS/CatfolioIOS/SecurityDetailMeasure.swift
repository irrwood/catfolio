import QuartzCore
import SwiftUI
import UIKit

/// Frame-level measurement for the security page's open, for comparing A
/// (`SecurityDetailSnapshotTransition`) with the native-zoom control.
///
///     --measure-security-detail --measure-auto-open
///
/// Per open it records:
///
/// - tap → the page's first drawn frame
/// - tap → the first frame carrying real data (`priceHistory`)
/// - every display-link interval in between, bucketed by how far past the
///   frame budget it ran
///
/// Read from `ProcessInfo` rather than `LaunchArguments`, which answers no to
/// everything in Release by design — and the measurement has to run in
/// Release, where the timings mean something. Opt-in only.
@MainActor
final class SecurityDetailMeasure {
    static let launchArgument = "--measure-security-detail"

    private static var flags: [String] { ProcessInfo.processInfo.arguments }
    private static var isOn: Bool { flags.contains(launchArgument) }

    /// Whether the presenter should open and close on its own, so the open can
    /// be measured without touch (`simctl` cannot send taps).
    static var isAutoDriving: Bool { isOn && flags.contains("--measure-auto-open") }

    private static var current: SecurityDetailMeasure?

    private let label: String
    private let started: CFTimeInterval
    private var contentAt: CFTimeInterval?
    private var dataAt: CFTimeInterval?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var intervals: [Double] = []

    private init(label: String) {
        self.label = label
        self.started = CACurrentMediaTime()
    }

    /// The tap. Called from the presenter, in the same run-loop turn.
    static func begin(_ label: String) {
        guard isOn else { return }
        current?.finish(reason: "superseded")
        current = SecurityDetailMeasure(label: label)
    }

    /// A frame of the page was drawn. On A the first call comes from the
    /// opening card, which is a skeleton rather than the real page — the tag
    /// distinguishes the two.
    static func contentAppeared(tag: String) {
        guard isOn, let current, current.contentAt == nil else { return }
        current.contentAt = CACurrentMediaTime()
        current.contentTag = tag
        current.startTicking()
    }

    /// The page drew a frame that carries real data.
    static func dataAppeared() {
        guard isOn, let current, current.dataAt == nil else { return }
        current.dataAt = CACurrentMediaTime()
        current.finish(reason: "data")
    }

    /// The open was abandoned or dismissed before data arrived.
    static func end() {
        guard isOn, let current else { return }
        current.finish(reason: "end")
    }

    private var contentTag = "?"

    private func startTicking() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard let last = lastTick else { return }
        intervals.append((now - last) * 1000)
        // 1.2s is well past any open; stop rather than measuring the whole life
        // of the page, which would bury the open's cost in idle frames.
        if now - started > 1.2 { finish(reason: "window") }
    }

    private func finish(reason: String) {
        link?.invalidate()
        link = nil
        guard Self.current === self else { return }
        Self.current = nil
        report(reason: reason)
    }

    private func report(reason: String) {
        let budget = 16.7
        let over = intervals.filter { $0 > budget }
        let hitch = intervals.filter { $0 > budget * 2 }
        let severe = intervals.filter { $0 > budget * 4 }
        let worst = intervals.max() ?? 0
        let total = intervals.reduce(0, +)
        let ratio = total > 0 ? over.reduce(0, +) / total * 100 : 0

        // One JSON object per open, so `reason` (which signal ended it) and the
        // raw times survive: the console line alone cannot be checked.
        let line = String(
            format: "{\"variant\":\"%@\",\"reason\":\"%@\",\"content_tag\":\"%@\",\"content_ms\":%@,"
                + "\"data_ms\":%@,\"frames\":%d,\"worst_ms\":%.1f,\"over16\":%d,\"over33\":%d,"
                + "\"over66\":%d,\"ratio_pct\":%.1f}",
            label, reason, contentTag,
            contentAt.map { String(format: "%.1f", ($0 - started) * 1000) } ?? "null",
            dataAt.map { String(format: "%.1f", ($0 - started) * 1000) } ?? "null",
            intervals.count, worst, over.count, hitch.count, severe.count, ratio)
        FileHandle.standardError.write(Data((line + "\n").utf8))
        appendToFile(line)
    }

    private func appendToFile(_ line: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = documents.appendingPathComponent("security-detail-measure.log")
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
