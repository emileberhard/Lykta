import Foundation
import LyktaCore
import SwiftUI
import Synchronization

nonisolated enum DrawnAvatar {
    static func png(_ node: Node) throws(PackedNode.Failure) -> Data {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let pending = Render()
        DispatchQueue.main.async {
            guard pending.isWaiting, ContinuousClock.now < deadline else { return }
            let result = MainActor.assumeIsolated { Result { () throws(PackedNode.Failure) in try render(node) } }
            pending.finish(ContinuousClock.now < deadline ? result : .failure(.deadline))
        }
        return try pending.wait()
    }

    @MainActor private static func render(_ node: Node) throws(PackedNode.Failure) -> Data {
        let renderer = ImageRenderer(content: NodeView(node).frame(width: 64, height: 64))
        renderer.scale = 4
        guard let data = renderer.uiImage?.pngData() else { throw .render }
        return data
    }
}

private nonisolated final class Render: Sendable {
    private let result = Mutex<Result<Data, PackedNode.Failure>?>(nil)
    private let done = DispatchSemaphore(value: 0)

    var isWaiting: Bool { result.withLock { $0 == nil } }

    func finish(_ outcome: Result<Data, PackedNode.Failure>) {
        result.withLock { if $0 == nil { $0 = outcome } }
        done.signal()
    }

    func wait() throws(PackedNode.Failure) -> Data {
        _ = done.wait(timeout: .now() + 2)
        return try result.withLock { outcome throws(PackedNode.Failure) in
            if outcome == nil { outcome = .failure(.deadline) }
            return try outcome!.get()
        }
    }
}
