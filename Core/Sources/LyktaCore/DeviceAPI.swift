public enum PushEnvironment: String, Codable, Sendable, CaseIterable {
    case development, production
}

public struct Registration: Codable, Sendable {
    public let environment: PushEnvironment
    public let appVersion: String

    public init(environment: PushEnvironment, appVersion: String) {
        self.environment = environment
        self.appVersion = appVersion
    }
}

public struct Credentials: Codable, Sendable {
    public let deviceSecret: String
    public let agentToken: String

    public init(deviceSecret: String, agentToken: String) {
        self.deviceSecret = deviceSecret
        self.agentToken = agentToken
    }
}

public struct DeviceReport: Codable, Sendable {
    public struct Observed: Codable, Sendable {
        public let id: String
        public let state: String

        public init(id: String, state: String) {
            self.id = id
            self.state = state
        }
    }

    public let pushToStartToken: String?
    public let appVersion: String
    public let bundleInstance: String
    public let activities: [Observed]

    public init(pushToStartToken: String?, appVersion: String, bundleInstance: String, activities: [Observed]) {
        self.pushToStartToken = pushToStartToken
        self.appVersion = appVersion
        self.bundleInstance = bundleInstance
        self.activities = activities
    }
}

public struct SyncResult: Codable, Sendable {
    public let end: [String]

    public init(end: [String]) {
        self.end = end
    }
}
