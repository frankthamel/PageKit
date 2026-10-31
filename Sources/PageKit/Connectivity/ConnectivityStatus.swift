/// A snapshot of the device's network connection.
public struct ConnectivityStatus: Equatable, Sendable {
    /// Whether the device has a usable network path.
    public let isOnline: Bool
    /// Whether the connection is costly to use, such as cellular or a personal hotspot.
    public let isExpensive: Bool
    /// Whether the user turned on Low Data Mode for this connection.
    public let isConstrained: Bool

    /// Creates a status. Only `isOnline` is required.
    public init(isOnline: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isOnline = isOnline
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// A plain, unrestricted online connection.
    public static let online = ConnectivityStatus(isOnline: true)
}
