import Foundation

public enum SignalCloseReason: Equatable, Sendable {
    case normal
    case reconnect
    case participantRemoved
    case roomDeleted
    case stateMismatch
    case unknown(code: Int, reason: String?)
}

public struct SignalCloseReasonMapper: Sendable {
    public init() {}

    public func map(code: Int, reason: String?) -> SignalCloseReason {
        switch code {
        case 1000:
            .normal
        case 4000:
            .reconnect
        case 4001:
            .participantRemoved
        case 4002:
            .roomDeleted
        case 4003:
            .stateMismatch
        default:
            .unknown(code: code, reason: reason)
        }
    }
}
