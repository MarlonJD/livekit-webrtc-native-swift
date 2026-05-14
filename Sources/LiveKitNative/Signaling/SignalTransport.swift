import Foundation

public enum SignalTransportFrame: Equatable, Sendable {
    case binary(Data)
    case text(String)
}

public enum SignalTransportCloseCode: Int, Equatable, Sendable {
    case normalClosure = 1000
    case goingAway = 1001
    case protocolError = 1002
    case unsupportedData = 1003
    case invalidFramePayloadData = 1007
    case policyViolation = 1008
    case messageTooBig = 1009
    case internalServerError = 1011
}

public protocol SignalTransport: Sendable {
    func connect(to url: URL) async throws
    func send(_ frame: SignalTransportFrame) async throws
    func receive() async throws -> SignalTransportFrame
    func sendPing() async throws
    func close(code: SignalTransportCloseCode, reason: Data?) async
}

public extension SignalTransport {
    func send(_ data: Data) async throws {
        try await send(.binary(data))
    }

    func close() async {
        await close(code: .normalClosure, reason: nil)
    }
}

public final class URLSessionWebSocketSignalTransport: SignalTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL) async throws {
        let task = session.webSocketTask(with: url)
        lock.withLock {
            self.task = task
        }
        task.resume()
    }

    public func send(_ frame: SignalTransportFrame) async throws {
        guard let task = lockedTask() else {
            throw LiveKitNativeError.notConnected
        }

        switch frame {
        case let .binary(data):
            try await task.send(.data(data))
        case let .text(text):
            try await task.send(.string(text))
        }
    }

    public func receive() async throws -> SignalTransportFrame {
        guard let task = lockedTask() else {
            throw LiveKitNativeError.notConnected
        }

        let message = try await task.receive()

        switch message {
        case let .data(data):
            return .binary(data)
        case let .string(text):
            return .text(text)
        @unknown default:
            throw LiveKitNativeError.invalidSignalFrame("Unknown URLSessionWebSocketTask message.")
        }
    }

    public func sendPing() async throws {
        guard let task = lockedTask() else {
            throw LiveKitNativeError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func close(code: SignalTransportCloseCode = .normalClosure, reason: Data? = nil) async {
        lock.withLock {
            task?.cancel(with: code.urlSessionCloseCode, reason: reason)
            task = nil
        }
    }

    private func lockedTask() -> URLSessionWebSocketTask? {
        lock.withLock {
            task
        }
    }
}

private extension SignalTransportCloseCode {
    var urlSessionCloseCode: URLSessionWebSocketTask.CloseCode {
        switch self {
        case .normalClosure:
            .normalClosure
        case .goingAway:
            .goingAway
        case .protocolError:
            .protocolError
        case .unsupportedData:
            .unsupportedData
        case .invalidFramePayloadData:
            .invalidFramePayloadData
        case .policyViolation:
            .policyViolation
        case .messageTooBig:
            .messageTooBig
        case .internalServerError:
            .internalServerError
        }
    }
}
