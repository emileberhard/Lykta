import Foundation
import LyktaCore

nonisolated enum WidgetReports {
    @concurrent static func make(pushToken: PushToken?, places: [WidgetPlace], at now: Date) async throws -> WidgetReport {
        let sequence = try AppGroup.lockingWidgets { directory in
            let file = directory.appending(path: "report-sequence")
            let last = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int64($0) } ?? 0
            let next = max(last + 1, Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))
            try String(next).write(to: file, atomically: true, encoding: .utf8)
            return next
        }
        return WidgetReport(sequence: sequence, pushToken: pushToken, layoutVersion: Layout.version, places: places)
    }
}
