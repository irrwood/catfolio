import Foundation

/// Decodes the bundled reference packages before a view asks for one.
///
/// Both catalogs are `static let`, so the first caller pays for the decode:
/// 1.9 MB of fund fees and 11 MB of company reference. That caller was a
/// view body — the holding detail page resolves a fund's fee and a sector as
/// its Data section scrolls into view — so the decode landed on the main
/// thread mid-gesture and stalled the scroll exactly once per launch.
///
/// Warming them on a background task moves that work to somewhere nothing is
/// waiting on it. Swift guarantees `static let` runs its initialiser once
/// even under contention, so a view that arrives first is no worse off than
/// before: it blocks on the same decode it would have performed itself.
enum ReferenceCatalogs {
    /// Fire-and-forget. Failures stay in the `Result` each catalog already
    /// carries, so a missing or malformed package surfaces where it is used
    /// rather than as a crash at launch.
    static func warm() {
        // This is opportunistic cache warming. Utility QoS keeps its 13 MB of
        // JSON parsing from competing with the first screen's animation.
        Task.detached(priority: .utility) {
            _ = try? FundFeeCatalog.bundled.get()
            _ = try? CompanyReferenceCatalog.bundled.get()
            _ = try? StockSplitCatalog.bundled.get()
        }
    }
}
