import Foundation
@testable import LiveKitNative

struct MockSignalServer: Sendable {
    var baseURL: URL

    init(baseURL: URL = URL(string: "wss://example.test")!) {
        self.baseURL = baseURL
    }

    func signalingURL(token: String = "token", connectOptions: ConnectOptions = .init()) throws -> URL {
        try SignalURLBuilder(serverURL: baseURL).build(
            token: token,
            reconnect: connectOptions.reconnect,
            autoSubscribe: connectOptions.autoSubscribe ?? true,
            connectOptions: connectOptions
        )
    }
}

struct MockSignalTransportCloseCall: Equatable, Sendable {
    var code: SignalTransportCloseCode
    var reason: Data?
}

actor MockSignalTransport: SignalTransport {
    private(set) var connectedURLs: [URL] = []
    private(set) var sentFrames: [SignalTransportFrame] = []
    private(set) var closeCalls: [MockSignalTransportCloseCall] = []
    private(set) var pingCount = 0

    private var incomingFrames: [SignalTransportFrame]
    private var receiveContinuations: [CheckedContinuation<SignalTransportFrame, any Error>] = []
    private var isClosed = false

    init(incomingFrames: [SignalTransportFrame] = []) {
        self.incomingFrames = incomingFrames
    }

    func enqueueIncomingFrame(_ frame: SignalTransportFrame) {
        if receiveContinuations.isEmpty {
            incomingFrames.append(frame)
        } else {
            receiveContinuations.removeFirst().resume(returning: frame)
        }
    }

    func connect(to url: URL) async throws {
        isClosed = false
        connectedURLs.append(url)
    }

    func send(_ frame: SignalTransportFrame) async throws {
        sentFrames.append(frame)
    }

    func receive() async throws -> SignalTransportFrame {
        guard !incomingFrames.isEmpty else {
            if isClosed {
                throw LiveKitNativeError.signalingClosed(code: nil, reason: "Mock transport closed.")
            }

            return try await withCheckedThrowingContinuation { continuation in
                receiveContinuations.append(continuation)
            }
        }

        return incomingFrames.removeFirst()
    }

    func sendPing() async throws {
        pingCount += 1
    }

    func close(code: SignalTransportCloseCode, reason: Data?) async {
        isClosed = true
        closeCalls.append(MockSignalTransportCloseCall(code: code, reason: reason))

        let continuations = receiveContinuations
        receiveContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: LiveKitNativeError.signalingClosed(code: code.rawValue, reason: "Mock transport closed."))
        }
    }
}
