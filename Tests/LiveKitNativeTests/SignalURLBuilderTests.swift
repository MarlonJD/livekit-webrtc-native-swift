import Foundation
import XCTest
@testable import LiveKitNative

final class SignalURLBuilderTests: XCTestCase {
    func testBuildsRTCURLWithProtocolParameters() throws {
        let builder = SignalURLBuilder(serverURL: try XCTUnwrap(URL(string: "https://example.livekit.cloud")))

        let url = try builder.build(
            token: "abc123",
            reconnect: true,
            autoSubscribe: false,
            connectOptions: ConnectOptions(version: "0.1.0-test")
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "example.livekit.cloud")
        XCTAssertEqual(components.path, "/rtc")
        XCTAssertEqual(query["access_token"], "abc123")
        XCTAssertEqual(query["reconnect"], "true")
        XCTAssertEqual(query["auto_subscribe"], "false")
        XCTAssertEqual(query["sdk"], "swift-native")
        XCTAssertEqual(query["version"], "0.1.0-test")
        XCTAssertEqual(query["protocol"], "9")
    }

    func testBuildsConnectionSettingQueryParametersWhenPresent() throws {
        let builder = SignalURLBuilder(
            serverURL: try XCTUnwrap(URL(string: "https://example.livekit.cloud?region=eu&adaptive_stream=false"))
        )

        let url = try builder.build(
            token: "abc123",
            connectOptions: ConnectOptions(
                adaptiveStream: true,
                subscriberAllowPause: true,
                autoSubscribeDataTrack: false
            )
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(query["region"], "eu")
        XCTAssertEqual(query["adaptive_stream"], "true")
        XCTAssertEqual(query["subscriber_allow_pause"], "true")
        XCTAssertEqual(query["auto_subscribe_data_track"], "false")
    }

    func testPreservesBasePathAndExistingQueryItems() throws {
        let builder = SignalURLBuilder(serverURL: try XCTUnwrap(URL(string: "https://example.com/livekit?region=eu")))

        let url = try builder.build(token: "token")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.path, "/livekit/rtc")
        XCTAssertEqual(query["region"], "eu")
        XCTAssertEqual(query["protocol"], "9")
    }

    func testRejectsMissingToken() {
        let builder = SignalURLBuilder(serverURL: URL(string: "wss://example.com")!)

        XCTAssertThrowsError(try builder.build(token: "")) { error in
            XCTAssertEqual(error as? LiveKitNativeError, .missingToken)
        }
    }
}
