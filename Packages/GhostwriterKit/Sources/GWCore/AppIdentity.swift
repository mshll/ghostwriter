import Darwin

public struct AppIdentity: Sendable, Hashable, Codable {
    public var bundleID: String
    public var name: String
    public var pid: pid_t

    public init(bundleID: String, name: String, pid: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}
