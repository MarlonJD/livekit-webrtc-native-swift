import Foundation
import SwiftProtobuf

public enum SignalConnectionState: String, Equatable, Sendable {
    case idle
    case connecting
    case connected
    case closed
}

public actor SignalConnection {
    public private(set) var state: SignalConnectionState = .idle

    private let transport: any SignalTransport
    private let codec: SignalFrameCodec

    public init(
        transport: any SignalTransport = URLSessionWebSocketSignalTransport(),
        codec: SignalFrameCodec = SignalFrameCodec()
    ) {
        self.transport = transport
        self.codec = codec
    }

    public func connect(to url: URL) async throws {
        state = .connecting

        do {
            try await transport.connect(to: url)
            state = .connected
        } catch {
            state = .closed
            throw error
        }
    }

    public func send<Message: SwiftProtobuf.Message & Sendable>(_ message: Message) async throws {
        try ensureConnected()
        try await transport.send(try codec.encode(message))
    }

    public func receive<Message: SwiftProtobuf.Message & Sendable>(_ messageType: Message.Type) async throws -> Message {
        try ensureConnected()

        switch try await transport.receive() {
        case let .binary(data):
            return try codec.decode(messageType, from: data)
        case let .text(text):
            throw LiveKitNativeError.invalidSignalFrame("Expected binary protobuf frame, received text frame: \(text)")
        }
    }

    public func sendPing() async throws {
        try ensureConnected()
        try await transport.sendPing()
    }

    public func close() async {
        await transport.close()
        state = .closed
    }

    private func ensureConnected() throws {
        guard state == .connected else {
            throw LiveKitNativeError.notConnected
        }
    }
}
