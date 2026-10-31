import os

/// The shared logger for PageKit, under the subsystem `PageKit`.
public enum PageKitLog {
    /// The logger PageKit writes to.
    public static let logger = Logger(subsystem: "PageKit", category: "Pagination")

    /// Marks PageKit's work in the Points of Interest track in Instruments.
    static let signposter = OSSignposter(subsystem: "PageKit", category: .pointsOfInterest)

    /// Runs `work` inside a signpost interval. Each interval has its own ID, so
    /// intervals from different paginators can overlap without being confused.
    static func interval<Result>(_ name: StaticString, around work: () throws -> Result) rethrows -> Result {
        try signposter.withIntervalSignpost(name, id: signposter.makeSignpostID(), around: work)
    }
}
