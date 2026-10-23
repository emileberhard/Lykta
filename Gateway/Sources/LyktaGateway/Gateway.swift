import Foundation
import LyktaCore

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
            let arguments = Array(CommandLine.arguments.dropFirst())
            let database = try value("LYKTA_DATABASE", default: "lykta.sqlite")
            switch arguments.first {
            case "events":
                try await printEvents(Store(path: database), arguments: Array(arguments.dropFirst()))
                return
            case "invite":
                let store = try Store(path: database)
                print(try await store.invite(now: Int(Date().timeIntervalSince1970)))
                return
            case "backup":
                guard arguments.count == 2 else { throw ConfigurationError("Usage: lykta-gateway backup PATH") }
                try Store.backup(database, to: arguments[1])
                return
            case nil:
                break
            default:
                throw ConfigurationError("Usage: lykta-gateway [events [--device UUID] [--limit N] | invite | backup PATH]")
            }
            let version = try settings["LYKTA_VERSION"].flatMap { $0.isEmpty ? nil : $0 }.map { text in
                guard let version = Version(text) else { throw ConfigurationError("LYKTA_VERSION must be MAJOR.MINOR.PATCH.") }
                return version
            }
            var keys: [PushEnvironment: (id: String, pem: String)] = [:]
            for environment in PushEnvironment.allCases {
                let prefix = "LYKTA_\(environment.rawValue.uppercased())_KEY"
                guard settings["\(prefix)_ID"] != nil || settings["\(prefix)_FILE"] != nil else { continue }
                keys[environment] = (try value("\(prefix)_ID"), try String(contentsOfFile: try value("\(prefix)_FILE"), encoding: .utf8))
            }
            guard !keys.isEmpty else { throw ConfigurationError("Set LYKTA_DEVELOPMENT_KEY_ID and _FILE, LYKTA_PRODUCTION_KEY_ID and _FILE, or both.") }
            let bundleID = try value("LYKTA_BUNDLE_ID")
            let teamID = try value("LYKTA_TEAM_ID")
            let push = try APNs(bundleID: bundleID, teamID: teamID, keys: keys)
            let store = try Store(path: database)
            let shutdown = Shutdown()
            let signals = shutdown.onSignals([SIGTERM, SIGINT])
            let api = API(store: store, maximumDevices: try number("LYKTA_MAX_DEVICES", default: 100),
                          maximumLiveActivities: try number("LYKTA_MAX_LIVE_ACTIVITIES", default: 5), environments: push.environments,
                          enrolment: Enrolment(appID: "\(teamID).\(bundleID)"), version: version, shutdown: shutdown)
            let host = try value("LYKTA_HOST", default: "127.0.0.1")
            let port = try number("LYKTA_PORT", default: 8080)
            let server = HTTPServer(host: host, port: port, maximumBodyBytes: 1 << 20, shutdown: shutdown) { await api.handle($0) }
            try await server.run {
                log("Lykta gateway \(version?.description ?? "of unknown version") listening on \(host):\(port)")
                try await Delivery(store: store, push: push, shutdown: shutdown).run()
            }
            withExtendedLifetime(signals) { log("Lykta gateway stopped after draining") }
        } catch {
            log("Lykta gateway stopped: \(error)")
            exit(1)
        }
    }

    private static func printEvents(_ store: Store, arguments: [String]) async throws {
        var device: UUID?
        var limit = 500
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch (flag, rest.popFirst()) {
            case let ("--device", value?):
                guard let id = UUID(uuidString: value) else { throw ConfigurationError("--device needs a device UUID.") }
                device = id
            case let ("--limit", value?):
                guard let number = Int(value), number > 0 else { throw ConfigurationError("--limit needs a positive integer.") }
                limit = number
            default:
                throw ConfigurationError("Usage: lykta-gateway events [--device UUID] [--limit N]")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for event in try await store.events(device: device, after: nil, limit: limit) {
            FileHandle.standardOutput.write(try encoder.encode(event) + Data("\n".utf8))
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
