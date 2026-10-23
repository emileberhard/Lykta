struct APIError: Error, Encodable, Sendable {
    enum Code: String, Encodable, Sendable {
        case invalidRequest = "invalid_request"
        case invalidName = "invalid_name"
        case invalidLayout = "invalid_layout"
        case unsupportedEnvironment = "unsupported_environment"
        case unauthorized
        case registrationClosed = "registration_closed"
        case registrationRefused = "registration_refused"
        case notFound = "not_found"
        case conflict
        case deviceNotReady = "device_not_ready"
        case tooManyActivities = "too_many_activities"
        case payloadTooLarge = "payload_too_large"
        case appUpdateRequired = "app_update_required"
        case `internal`

        var status: Int {
            switch self {
            case .invalidRequest, .invalidName, .invalidLayout, .unsupportedEnvironment: 400
            case .unauthorized: 401
            case .registrationClosed, .registrationRefused: 403
            case .notFound: 404
            case .deviceNotReady, .tooManyActivities, .conflict, .appUpdateRequired: 409
            case .payloadTooLarge: 413
            case .internal: 500
            }
        }
    }

    let code: Code
    let message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code = "error", message
    }
}
