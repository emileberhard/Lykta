import Foundation

@main
enum Gateway {
    static func main() async {
        do {
            let settings = ProcessInfo.processInfo.environment
            func value(_ name: String, default fallback: String? = nil) throws -> String {
                guard let value = settings[name] ?? fallback, !value.isEmpty else { throw ConfigurationError("Set \(name).") }
                return value
            }
            func number(_ name: String, default fallback: Int) throws -> Int {
                guard let number = Int(try value(name, default: String(fallback))), number > 0 else {
                    throw ConfigurationError("\(name) must be a positive integer.")
                }
                return number
            }
            var keys: [PushEnvironment: (id: String, pem: String)] = [:]
            for environment in PushEnvironment.allCases {
                let prefix = "LYKTA_\(environment.rawValue.uppercased())_KEY"
                guard settings["\(prefix)_ID"] != nil || settings["\(prefix)_FILE"] != nil else { continue }
                keys[environment] = (try value("\(prefix)_ID"), try String(contentsOfFile: try value("\(prefix)_FILE"), encoding: .utf8))
            }
            guard !keys.isEmpty else { throw ConfigurationError("Set LYKTA_DEVELOPMENT_KEY_ID and _FILE, LYKTA_PRODUCTION_KEY_ID and _FILE, or both.") }
            let push = try APNs(bundleID: try value("LYKTA_BUNDLE_ID"), teamID: try value("LYKTA_TEAM_ID"), keys: keys)
            let store = try Store(path: try value("LYKTA_DATABASE", default: "lykta.sqlite"),
                                  maximumDevices: try number("LYKTA_MAX_DEVICES", default: 100),
                                  maximumLiveActivities: try number("LYKTA_MAX_LIVE_ACTIVITIES", default: 5))
            let api = API(store: store, environments: push.environments)
            let host = try value("LYKTA_HOST", default: "127.0.0.1")
            let port = try number("LYKTA_PORT", default: 8080)
            let server = HTTPServer(host: host, port: port, maximumBodyBytes: 65_536) { await api.handle($0) }
            log("Lykta gateway listening on \(host):\(port)")
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask { try await Delivery(store: store, push: push).run() }
                group.addTask { try await server.run() }
            }
        } catch {
            log("Lykta gateway stopped: \(error)")
            exit(1)
        }
    }
}

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date().ISO8601Format()) \(message)\n".utf8))
}
