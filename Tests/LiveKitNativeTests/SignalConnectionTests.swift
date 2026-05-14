import Foundation
import LiveKitNativeProtocol
import SwiftProtobuf
import XCTest
@testable import LiveKitNative

final class SignalConnectionTests: XCTestCase {
    func testConnectSendsAndClosesThroughTransport() async throws {
        let transport = MockSignalTransport()
        let connection = SignalConnection(transport: transport)
        let url = try XCTUnwrap(URL(string: "wss://example.test/rtc"))

        try await connection.connect(to: url)

        var ping = Livekit_Ping()
        ping.timestamp = 42
        var request = Livekit_SignalRequest()
        request.pingReq = ping
        try await connection.send(request)
        try await connection.sendPing()
        await connection.close()

        let connectedURLs = await transport.connectedURLs
        let sentFrames = await transport.sentFrames
        let pingCount = await transport.pingCount
        let closeCalls = await transport.closeCalls
        let connectionState = await connection.state

        XCTAssertEqual(connectedURLs, [url])
        XCTAssertEqual(sentFrames.count, 1)
        XCTAssertEqual(pingCount, 1)
        XCTAssertEqual(closeCalls, [MockSignalTransportCloseCall(code: .normalClosure, reason: nil)])
        XCTAssertEqual(connectionState, .closed)

        guard case let .binary(data) = sentFrames[0] else {
            return XCTFail("Expected a binary protobuf frame.")
        }

        let decoded = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testReceiveDecodesBinaryFrame() async throws {
        var pong = Livekit_Pong()
        pong.lastPingTimestamp = 42
        pong.timestamp = 84
        var response = Livekit_SignalResponse()
        response.pongResp = pong

        let encoded = try SignalFrameCodec().encode(response)
        let transport = MockSignalTransport(incomingFrames: [.binary(encoded)])
        let connection = SignalConnection(transport: transport)
        try await connection.connect(to: URL(string: "wss://example.test/rtc")!)

        let decoded = try await connection.receive(Livekit_SignalResponse.self)

        XCTAssertEqual(decoded, response)
    }

    func testReceiveRejectsTextFrames() async throws {
        let transport = MockSignalTransport(incomingFrames: [.text("not protobuf")])
        let connection = SignalConnection(transport: transport)
        try await connection.connect(to: URL(string: "wss://example.test/rtc")!)

        do {
            let _: Livekit_SignalResponse = try await connection.receive(Livekit_SignalResponse.self)
            XCTFail("Expected text frame rejection.")
        } catch let error as LiveKitNativeError {
            guard case .invalidSignalFrame = error else {
                return XCTFail("Expected invalidSignalFrame, got \(error).")
            }
        }
    }

    func testSendBeforeConnectFails() async throws {
        let connection = SignalConnection(transport: MockSignalTransport())

        await XCTAssertThrowsErrorAsync {
            var request = Livekit_SignalRequest()
            request.ping = 42
            try await connection.send(request)
        }
    }
}
