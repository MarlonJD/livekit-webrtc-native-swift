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

    init(incomingFrames: [SignalTransportFrame] = []) {
        self.incomingFrames = incomingFrames
    }

    func enqueueIncomingFrame(_ frame: SignalTransportFrame) {
        incomingFrames.append(frame)
    }

    func connect(to url: URL) async throws {
        connectedURLs.append(url)
    }

    func send(_ frame: SignalTransportFrame) async throws {
        sentFrames.append(frame)
    }

    func receive() async throws -> SignalTransportFrame {
        guard !incomingFrames.isEmpty else {
            throw LiveKitNativeError.signalingClosed(code: nil, reason: "No mock frame queued.")
        }

        return incomingFrames.removeFirst()
    }

    func sendPing() async throws {
        pingCount += 1
    }

    func close(code: SignalTransportCloseCode, reason: Data?) async {
        closeCalls.append(MockSignalTransportCloseCall(code: code, reason: reason))
    }
}
