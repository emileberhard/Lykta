import Foundation

public struct Effects: Equatable, Sendable {
    private enum Change: Equatable, Sendable {
        case set(JSONValue)
        case add(Double)
        case addSeconds(since: String)
        case now(plus: Double)
    }

    private let changes: [String: Change]

    init(_ fields: Fields) throws {
        var changes: [String: Change] = [:]
        let set: [String: JSONValue] = try fields.optional("set") ?? [:]
        let add: [String: Amount] = try fields.optional("add") ?? [:]
        let now: [String: Double] = try fields.optional("now") ?? [:]
        for (path, value) in set { changes[path] = .set(value) }
        for (path, amount) in add {
            switch amount {
            case let .number(number): changes[path] = .add(number)
            case let .since(date):
                fields.record("button.add.since", at: "add")
                changes[path] = .addSeconds(since: date)
            }
        }
        for (path, offset) in now { changes[path] = .now(plus: offset) }
        guard changes.count == set.count + add.count + now.count else {
            throw fields.invalid("set, add and now name a data path at most once")
        }
        let paths = changes.keys.sorted()
        if let path = paths.first(where: { !(1...256).contains($0.utf8.count) || $0.contains("{{") }) {
            throw fields.invalid("\"\(path)\" is not a data path such as \"items.0.count\"")
        }
        for path in paths {
            let parts = path.split(separator: ".", omittingEmptySubsequences: false)
            if let outer = parts.indices.dropLast().map({ parts[...$0].joined(separator: ".") }).first(where: { changes[$0] != nil }) {
                throw fields.invalid("\"\(outer)\" contains \"\(path)\"; change each value once")
            }
        }
        guard add.values.allSatisfy(\.isFinite), now.values.allSatisfy(\.isFinite) else {
            throw fields.invalid("add and now take finite numbers")
        }
        self.changes = changes
    }

    public func applied(to data: JSONValue, at now: Date) throws(LayoutError) -> JSONValue {
        let seconds = now.timeIntervalSince1970.rounded()
        var result = data
        for (path, change) in changes {
            let value: JSONValue = switch change {
            case let .set(value): value
            case let .add(amount): .number(try data.number(at: path) + amount)
            case let .addSeconds(since): .number(try data.number(at: path) + seconds - data.date(at: since))
            case let .now(offset): .number(seconds + offset)
            }
            if case let .number(number) = value, !number.isFinite { throw LayoutError("\"\(path)\" would not be a finite number") }
            result = try result.replacing(path, with: value)
        }
        return result
    }

    private enum Amount: Decodable {
        case number(Double)
        case since(String)

        var isFinite: Bool {
            if case let .number(number) = self { number.isFinite } else { true }
        }

        init(from decoder: any Decoder) throws {
            if let number = try? decoder.singleValueContainer().decode(Double.self) {
                self = .number(number)
                return
            }
            let fields = try decoder.container(keyedBy: Key.self)
            try fields.allowOnly(["since"])
            self = .since(try fields.text("since", maximumLength: 256))
        }
    }
}

extension JSONValue {
    func number(at path: String) throws(LayoutError) -> Double {
        guard case let .number(number) = try value(at: path) else { throw LayoutError("data \"\(path)\" is not a number") }
        return number
    }

    func date(at path: String) throws(LayoutError) -> Double {
        let value = try value(at: path)
        if case let .number(seconds) = value { return seconds }
        guard case let .string(text) = value, let date = Layout.date(text) else { throw LayoutError("data \"\(path)\" is not a date") }
        return date.timeIntervalSince1970
    }
}
