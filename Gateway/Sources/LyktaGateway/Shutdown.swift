import Dispatch
import Foundation
import Synchronization

final class Shutdown: Sendable {
    static let drainLimit = Duration.seconds(5)

    private let requested = Atomic<Bool>(false)

    var isRequested: Bool {
        requested.load(ordering: .acquiring)
    }

    func request() {
        if !requested.exchange(true, ordering: .acquiringAndReleasing) {
            log("Draining: finishing pushes in flight before closing the listener")
        }
    }

    func onSignals(_ numbers: [Int32]) -> [any DispatchSourceSignal] {
        numbers.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number)
            source.setEventHandler { [self] in request() }
            source.resume()
            return source
        }
    }
}
