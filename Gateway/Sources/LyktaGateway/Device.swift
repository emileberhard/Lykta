import Foundation
import LyktaCore

struct Device: Sendable {
    let id: UUID
    let environment: PushEnvironment
    let pushToken: PushToken?
    let appVersion: String
    let layoutVersion: Version?
}

enum Admission: Sendable {
    case attested(keyID: Data)
    case invited(String)
}
