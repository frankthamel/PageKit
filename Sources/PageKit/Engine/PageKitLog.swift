import os

/// The shared logger for PageKit, under the subsystem `PageKit`.
public enum PageKitLog {
    /// The logger PageKit writes to.
    public static let logger = Logger(subsystem: "PageKit", category: "Pagination")
}
