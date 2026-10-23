import Foundation
import LyktaCore
import MetricKit

final class Telemetry {
    private let queue = EventQueue()
    private let metrics = MetricManager()
    private var upload: ((EventBatch) async throws -> Void)?
    private var flushTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?

    func start(launch detail: @autoclosure () -> [String: JSONValue]) {
        guard metricsTask == nil else { return }
        record("app.launch", detail())
        metricsTask = Task {
            await withDiscardingTaskGroup { group in
                group.addTask { await self.observeDiagnostics() }
                group.addTask { await self.observeMetrics() }
            }
        }
    }

    func record(_ name: String, activity: UUID? = nil, _ detail: [String: JSONValue] = [:]) {
        queue.append(Event(id: UUID(), at: .now, name: name, activity: activity, detail: .object(detail)))
        scheduleFlush()
    }

    func startUploading(with send: @escaping (EventBatch) async throws -> Void) {
        upload = send
        scheduleFlush()
    }

    func reset() {
        upload = nil
        queue.clear()
    }

    private func observeDiagnostics() async {
        for await report in metrics.diagnosticReports {
            record("metrickit.diagnostic", Self.detail(of: report))
        }
    }

    private func observeMetrics() async {
        for await report in metrics.metricReports {
            record("metrickit.metrics", Self.detail(of: report))
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .seconds(1))
            await flush()
            flushTask = nil
        }
    }

    private func flush() async {
        guard let upload else { return }
        while !queue.events.isEmpty {
            let batch = queue.batch()
            do {
                try await upload(EventBatch(events: batch))
            } catch let error as AppError where error.status == 400 || error.status == 413 {
                queue.remove(batch)
                queue.append(Event(id: UUID(), at: .now, name: "telemetry.rejected", activity: nil, detail: .object([
                    "events": .number(Double(batch.count)), "error": .string(error.localizedDescription),
                ])))
                return
            } catch {
                return
            }
            queue.remove(batch)
        }
    }

    private static func detail(of report: some Encodable) -> [String: JSONValue] {
        do {
            let data = try JSONEncoder().encode(report)
            guard case let .object(fields) = try JSONDecoder().decode(JSONValue.self, from: data) else { return ["error": .string("not an object")] }
            guard data.count > Event.maximumDetailBytes else { return fields }
            return fields.filter { $0.value.json.count < 4096 }.merging(["truncatedFrom": .number(Double(data.count))]) { $1 }
        } catch {
            return ["error": .string("\(error)")]
        }
    }
}
