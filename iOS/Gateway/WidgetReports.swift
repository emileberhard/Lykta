import Foundation

nonisolated enum WidgetReports {
    static func sequence(at now: Date) throws -> Int64 {
        try AppGroup.lockingWidgets { directory in
            let file = directory.appending(path: "report-sequence")
            let last: Int64
            do {
                guard let value = Int64(try String(contentsOf: file, encoding: .utf8)) else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
                }
                last = value
            } catch CocoaError.fileReadNoSuchFile {
                last = 0
            }
            let next = max(last + 1, Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))
            try String(next).write(to: file, atomically: true, encoding: .utf8)
            return next
        }
    }
}
