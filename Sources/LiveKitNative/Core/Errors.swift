import Foundation

public enum LiveKitNativeError: Error, Equatable, Sendable {
    case invalidURL(String)
    case missingToken
    case notConnected
    case permissionDenied(action: String)
    case signalingClosed(code: Int?, reason: String?)
    case invalidSignalFrame(String)
    case requestFailed(action: String, reason: String, message: String)
    case requestTimedOut(action: String)
    case productionReadinessFailed([String])
    case notImplemented(String)
}

extension LiveKitNativeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidURL(reason):
            "Invalid LiveKit URL: \(reason)"
        case .missingToken:
            "A LiveKit access token is required."
        case .notConnected:
            "The room is not connected."
        case let .permissionDenied(action):
            "LiveKit permission denied for \(action)."
        case let .signalingClosed(code, reason):
            "LiveKit signaling closed with code \(code.map(String.init) ?? "unknown"): \(reason ?? "no reason")."
        case let .invalidSignalFrame(reason):
            "Invalid LiveKit signaling frame: \(reason)"
        case let .requestFailed(action, reason, message):
            "LiveKit request failed for \(action) with reason \(reason): \(message)"
        case let .requestTimedOut(action):
            "LiveKit request timed out for \(action)."
        case let .productionReadinessFailed(blockers):
            "LiveKitNative is not production-ready: \(blockers.joined(separator: "; "))"
        case let .notImplemented(feature):
            "\(feature) is not implemented yet."
        }
    }
}
