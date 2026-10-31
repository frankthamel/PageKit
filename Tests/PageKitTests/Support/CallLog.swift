/// Counts calls into a source, safely across tasks.
actor CallLog {
    private(set) var count = 0

    /// Records a call and returns its number, starting at 1.
    @discardableResult
    func record() -> Int {
        count += 1
        return count
    }
}
