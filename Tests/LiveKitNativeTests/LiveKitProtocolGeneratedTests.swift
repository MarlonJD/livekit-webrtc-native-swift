import LiveKitNativeProtocol
import XCTest

final class LiveKitProtocolGeneratedTests: XCTestCase {
    func testManifestExposesPinnedClientProtocol() {
        XCTAssertEqual(LiveKitProtocolManifest.protocolVersion, 9)
        XCTAssertEqual(
            LiveKitProtocolManifest.pinnedCommit,
            "765a80e4298e376593859c3f11cf748c725f68f9"
        )
    }

    func testSignalRequestAndResponseRoundTrip() throws {
        var ping = Livekit_Ping()
        ping.timestamp = 123
        ping.rtt = 7

        var request = SignalRequestFrame()
        request.pingReq = ping

        let requestData = try request.serializedData()
        let decodedRequest = try SignalRequestFrame(serializedBytes: requestData)

        XCTAssertEqual(decodedRequest, request)

        var pong = Livekit_Pong()
        pong.lastPingTimestamp = 123
        pong.timestamp = 456

        var response = SignalResponseFrame()
        response.pongResp = pong

        let responseData = try response.serializedData()
        let decodedResponse = try SignalResponseFrame(serializedBytes: responseData)

        XCTAssertEqual(decodedResponse, response)
    }
}
