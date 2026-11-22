import Synchronization

final class Signal: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var nextID: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    var generation: UInt64 {
        state.withLock(\.generation)
    }

    func notify() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.generation &+= 1
            let current = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: true)
            return current
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait(since seen: UInt64, timeout: Duration) async throws {
        guard timeout > .zero else { return }
        if state.withLock({ $0.generation != seen }) { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForChange(since: seen) }
            group.addTask { try await Task.sleep(for: timeout) }
            defer { group.cancelAll() }
            try await group.next()
        }
        try Task.checkCancellation()
    }

    private func waitForChange(since seen: UInt64) async {
        let id = state.withLock { state -> UInt64 in
            state.nextID &+= 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResume = state.withLock { state -> Bool in
                    if state.generation != seen || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
}
