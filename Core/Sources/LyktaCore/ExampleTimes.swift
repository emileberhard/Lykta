import Foundation

extension JSONValue {
    private static let exampleTime = 1_793_000_000.0
    private static let exampleWindow = 172_800.0

    public func movingExampleTimes(to date: Date) -> JSONValue {
        moved(by: (date.timeIntervalSince1970 - Self.exampleTime).rounded())
    }

    private func moved(by shift: Double) -> JSONValue {
        switch self {
        case let .number(number) where abs(number - Self.exampleTime) < Self.exampleWindow: .number(number + shift)
        case let .object(fields): .object(fields.mapValues { $0.moved(by: shift) })
        case let .array(items): .array(items.map { $0.moved(by: shift) })
        case .number, .string, .bool, .null: self
        }
    }
}
