import QuartzCore
import SwiftUI
import UIKit

/// Frame-level measurement for the security page's open, for comparing A
/// (`SecurityDetailSnapshotTransition`) with the native-zoom control.
///
/// Two ways in, both opt-in and both off by default:
///
/// - the in-app panel at Settings → 走势转场测量, which is what a phone run
///   uses (there is no way to send taps from outside, so the panel records the
///   opens you make by hand);
/// - `--measure-security-detail --measure-auto-open`, which drives the opens
///   itself, for scripted simulator runs.
///
/// Per open it records tap → the page's first drawn frame, tap → the first
/// frame carrying real data, and every display-link interval in between,
/// bucketed by how far past the frame budget it ran.
///
/// Off, this costs one `UserDefaults` read per open and allocates nothing. It
/// is not `#if DEBUG` on purpose: the timings only mean something in Release,
/// where the compiler is not the thing being measured.
@MainActor
final class SecurityDetailMeasure {
    static let launchArgument = "--measure-security-detail"
    static let autoDriveArgument = "--measure-auto-open"
    /// The panel writes here, so an opt-in survives the relaunch that switching
    /// from Debug to Release for a device run requires.
    static let preferenceKey = "securityDetail.measure"

    private static var flags: [String] { ProcessInfo.processInfo.arguments }

    static var isEnabled: Bool {
        if flags.contains(launchArgument) { return true }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// Whether the presenter should open and close on its own, so the open can
    /// be measured without touch (`simctl` cannot send taps).
    static var isAutoDriving: Bool {
        isEnabled && flags.contains(autoDriveArgument)
    }

    /// The panel row's first key. Read through here rather than from
    /// `ProcessInfo` at the call site, which would allocate the argument list
    /// on every settings-page build.
    static var wasAskedFor: Bool { flags.contains(panelArgument) }
    static let panelArgument = "--show-transition-measure"

    // MARK: Results

    struct Measurement: Identifiable, Codable, Equatable {
        var id = UUID()
        var at = Date()
        var variant: String
        var reason: String
        var contentTag: String
        var contentMs: Double?
        var dataMs: Double?
        var frames: Int
        var worstMs: Double
        var over16: Int
        var over33: Int
        var over66: Int
        var ratioPct: Double
    }

    /// Kept in memory for the panel, oldest first. The file below is the record
    /// that survives a relaunch; this is what the table draws.
    private(set) static var results: [Measurement] = []
    private static let resultsLimit = 100

    static func reset() {
        results = []
    }

    /// Appends a row straight into the table. Only for the summaries/export
    /// tests, which have no way to drive a real open.
    static func record(_ measurement: Measurement) {
        results.append(measurement)
    }

    /// Tab separated, with a header, so a paste into Numbers or Excel lands in
    /// columns without any import step.
    static var exportText: String {
        var lines = ["variant\treason\tcontent_tag\tcontent_ms\tdata_ms\tframes\tworst_ms\tover16\tover33\tover66\tratio_pct"]
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        for row in results {
            lines.append([
                row.variant,
                row.reason,
                row.contentTag,
                row.contentMs.map { String(format: "%.1f", $0) } ?? "",
                row.dataMs.map { String(format: "%.1f", $0) } ?? "",
                "\(row.frames)",
                String(format: "%.1f", row.worstMs),
                "\(row.over16)",
                "\(row.over33)",
                "\(row.over66)",
                String(format: "%.1f", row.ratioPct),
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// Summarised per variant and warmth, which is the comparison itself: the
    /// warm row is the one that decides whether the page can be grown live.
    struct Summary: Identifiable {
        var id: String { "\(variant)|\(group)" }
        let variant: String
        let group: String
        let opens: Int
        let contentMs: Double
        let worstMs: Double
        let over33: Int
        let over66: Int
    }

    static var summaries: [Summary] {
        var buckets: [String: [Measurement]] = [:]
        for (index, row) in results.enumerated() {
            // The first open of each variant run is the cold one: its caches
            // have just been cleared, or the app has just started.
            let isCold = results.prefix(index).allSatisfy { $0.variant != row.variant }
            let group = isCold ? "cold" : "warm"
            buckets["\(row.variant)|\(group)", default: []].append(row)
        }
        return buckets
            .map { key, rows -> Summary in
                let parts = key.split(separator: "|")
                let contents = rows.compactMap(\.contentMs)
                return Summary(
                    variant: String(parts[0]),
                    group: String(parts[1]),
                    opens: rows.count,
                    contentMs: contents.isEmpty ? 0 : contents.reduce(0, +) / Double(contents.count),
                    worstMs: rows.map(\.worstMs).max() ?? 0,
                    over33: rows.map(\.over33).reduce(0, +),
                    over66: rows.map(\.over66).reduce(0, +))
            }
            .sorted { ($0.variant, $0.group) < ($1.variant, $1.group) }
    }

    // MARK: Recording

    private static var current: SecurityDetailMeasure?

    private let label: String
    private let started: CFTimeInterval
    private var contentAt: CFTimeInterval?
    private var dataAt: CFTimeInterval?
    private var contentTag = "?"
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var intervals: [Double] = []

    private init(label: String) {
        self.label = label
        self.started = CACurrentMediaTime()
    }

    /// The tap. Called from the presenter, in the same run-loop turn.
    static func begin(_ label: String) {
        guard isEnabled else { return }
        current?.finish(reason: "superseded")
        current = SecurityDetailMeasure(label: label)
    }

    /// A frame of the page was drawn. On A the first call may come from the
    /// opening card, which is a skeleton rather than the real page — the tag
    /// distinguishes the two.
    static func contentAppeared(tag: String) {
        guard isEnabled, let current, current.contentAt == nil else { return }
        current.contentAt = CACurrentMediaTime()
        current.contentTag = tag
        current.startTicking()
    }

    /// The page drew a frame that carries real data.
    static func dataAppeared() {
        guard isEnabled, let current, current.dataAt == nil else { return }
        current.dataAt = CACurrentMediaTime()
        current.finish(reason: "data")
    }

    /// The open was abandoned or dismissed before data arrived.
    static func end() {
        guard isEnabled, let current else { return }
        current.finish(reason: "end")
    }

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
        let contentMs = contentAt.map { ($0 - started) * 1000 }
        let dataMs = dataAt.map { ($0 - started) * 1000 }

        Self.results.append(Measurement(
            variant: label, reason: reason, contentTag: contentTag,
            contentMs: contentMs, dataMs: dataMs, frames: intervals.count,
            worstMs: worst, over16: over.count, over33: hitch.count,
            over66: severe.count, ratioPct: ratio))
        if Self.results.count > Self.resultsLimit { Self.results.removeFirst() }

        // One JSON object per open, so `reason` (which signal ended it) and the
        // raw times survive: the panel's table alone cannot be checked.
        let line = String(
            format: "{\"variant\":\"%@\",\"reason\":\"%@\",\"content_tag\":\"%@\",\"content_ms\":%@,"
                + "\"data_ms\":%@,\"frames\":%d,\"worst_ms\":%.1f,\"over16\":%d,\"over33\":%d,"
                + "\"over66\":%d,\"ratio_pct\":%.1f}",
            label, reason, contentTag,
            contentMs.map { String(format: "%.1f", $0) } ?? "null",
            dataMs.map { String(format: "%.1f", $0) } ?? "null",
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
