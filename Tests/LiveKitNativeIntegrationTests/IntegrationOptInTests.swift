import Foundation
import LiveKitNative
import XCTest

final class IntegrationOptInTests: XCTestCase {
    func testIntegrationSuiteIsOptIn() throws {
        let harness = try LiveKitIntegrationHarness.load()

        XCTAssertFalse(harness.roomPrefix.isEmpty)
    }

    func testHarnessRequiresConfigurationAfterOptIn() {
        XCTAssertThrowsError(
            try LiveKitIntegrationHarness.load(environment: [
                LiveKitIntegrationHarness.runIntegrationKey: "1",
            ])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(LiveKitIntegrationHarness.liveKitURLKey)
            )
        }
    }

    func testHarnessBuildsRoomScopedLiveKitToken() throws {
        let harness = try LiveKitIntegrationHarness.load(
            environment: [
                LiveKitIntegrationHarness.runIntegrationKey: "1",
                LiveKitIntegrationHarness.liveKitURLKey: "ws://127.0.0.1:7880",
                LiveKitIntegrationHarness.apiKeyKey: "devkey",
                LiveKitIntegrationHarness.apiSecretKey: "secret",
            ],
            now: Date(timeIntervalSince1970: 1_700_000_000),
            uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )

        let token = try harness.token(
            identity: "swift-native-a",
            roomName: "integration-room",
            ttlSeconds: 60
        )
        let parts = token.split(separator: ".").map(String.init)

        XCTAssertEqual(parts.count, 3)

        let payloadData = try XCTUnwrap(Data(base64URLEncoded: parts[1]))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        let video = try XCTUnwrap(payload["video"] as? [String: Any])

        XCTAssertEqual(payload["iss"] as? String, "devkey")
        XCTAssertEqual(payload["sub"] as? String, "swift-native-a")
        XCTAssertEqual(video["room"] as? String, "integration-room")
        XCTAssertEqual(video["roomJoin"] as? Bool, true)
        XCTAssertEqual(video["canPublish"] as? Bool, true)
        XCTAssertEqual(video["canSubscribe"] as? Bool, true)
        XCTAssertEqual(video["canPublishData"] as? Bool, true)
    }

    func testLiveKitServerConnectsAndDisconnects() async throws {
        let harness = try LiveKitIntegrationHarness.load()
        let roomName = harness.roomName(suffix: "connect")
        let identity = "swift-native-connect"
        let room = Room(
            options: RoomOptions(
                defaultAutoSubscribe: true,
                defaultAdaptiveStream: true,
                defaultSubscriberAllowPause: true,
                defaultAutoSubscribeDataTrack: true
            )
        )
        let token = try harness.token(identity: identity, roomName: roomName)

        do {
            try await withLiveKitIntegrationTimeout(seconds: 15) {
                try await room.connect(url: harness.liveKitURL, token: token)
            }
        } catch {
            await room.disconnect()
            throw error
        }

        XCTAssertEqual(room.connectionState, .connected)
        XCTAssertEqual(room.localParticipant.identity, identity)

        await room.disconnect()

        XCTAssertEqual(room.connectionState, .disconnected)
    }
}
