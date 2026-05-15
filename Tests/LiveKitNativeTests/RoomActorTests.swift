import Foundation
import XCTest
@testable import LiveKitNative
@testable import LiveKitNativeWebRTC

final class RoomActorTests: XCTestCase {
    func testParticipantUpdatesAreIdempotentBySid() async {
        let actor = RoomActor(localParticipant: LocalParticipant(identity: "me"))
        let firstUpdate = ParticipantSnapshot(sid: "PA_alice", identity: "alice", name: "Alice")

        let firstResult = await actor.applyParticipantUpdates([firstUpdate])
        let secondResult = await actor.applyParticipantUpdates([firstUpdate])
        let snapshot = await actor.snapshot()

        XCTAssertEqual(firstResult.1.count, 1)
        XCTAssertEqual(secondResult.1.count, 0)
        XCTAssertEqual(snapshot.remoteParticipants.count, 1)
        XCTAssertEqual(snapshot.remoteParticipants.first?.identity, "alice")
    }

    func testParticipantUpdatesMutateExistingParticipant() async {
        let actor = RoomActor(localParticipant: LocalParticipant(identity: "me"))

        _ = await actor.applyParticipantUpdates([
            ParticipantSnapshot(sid: "PA_alice", identity: "alice", name: "Alice"),
        ])
        _ = await actor.applyParticipantUpdates([
            ParticipantSnapshot(sid: "PA_alice", identity: "alice", name: "Alice Smith", metadata: "updated"),
        ])

        let participant = await actor.snapshot().remoteParticipants.first

        XCTAssertEqual(participant?.name, "Alice Smith")
        XCTAssertEqual(participant?.metadata, "updated")
    }

    func testTrackPublicationsAreIdempotentBySid() async {
        let actor = RoomActor(localParticipant: LocalParticipant(identity: "me"))
        let update = ParticipantSnapshot(
            sid: "PA_alice",
            identity: "alice",
            name: "Alice",
            trackPublications: [
                TrackPublicationSnapshot(sid: "TR_camera", name: "camera", kind: .video, source: .camera),
            ]
        )

        let firstResult = await actor.applyParticipantUpdates([update])
        let secondResult = await actor.applyParticipantUpdates([update])
        let participant = await actor.snapshot().remoteParticipants.first

        XCTAssertEqual(firstResult.1.count, 2)
        XCTAssertEqual(secondResult.1.count, 0)
        XCTAssertEqual(participant?.trackPublications.count, 1)
        XCTAssertEqual(participant?.trackPublications.first?.sid, "TR_camera")

        guard case .participantConnected = firstResult.1[0] else {
            return XCTFail("Expected participantConnected before trackPublished.")
        }

        guard case let .trackPublished(publication, publishedParticipant) = firstResult.1[1] else {
            return XCTFail("Expected trackPublished event.")
        }
        XCTAssertEqual(publication.sid, "TR_camera")
        XCTAssertEqual(publishedParticipant.sid, "PA_alice")
    }

    func testTrackMuteChangesMutateExistingPublicationAndEmitEvent() async {
        let actor = RoomActor(localParticipant: LocalParticipant(identity: "me"))
        _ = await actor.applyParticipantUpdates([
            ParticipantSnapshot(
                sid: "PA_alice",
                identity: "alice",
                trackPublications: [
                    TrackPublicationSnapshot(sid: "TR_camera", name: "camera", kind: .video, source: .camera),
                ]
            ),
        ])

        let result = await actor.applyTrackMute(sid: "TR_camera", muted: true)
        let participant = result.0.remoteParticipants.first
        let publication = participant?.trackPublications.first

        XCTAssertEqual(publication?.isMuted, true)
        XCTAssertEqual(result.1.count, 1)

        guard case let .trackMuteChanged(mutedPublication, mutedParticipant, isMuted) = result.1[0] else {
            return XCTFail("Expected trackMuteChanged event.")
        }
        XCTAssertEqual(mutedPublication.sid, "TR_camera")
        XCTAssertEqual(mutedParticipant.sid, "PA_alice")
        XCTAssertTrue(isMuted)

        let duplicateResult = await actor.applyTrackMute(sid: "TR_camera", muted: true)
        XCTAssertEqual(duplicateResult.1.count, 0)
    }

    func testTrackPublicationRemovalEmitsTrackUnpublished() async {
        let actor = RoomActor(localParticipant: LocalParticipant(identity: "me"))
        _ = await actor.applyParticipantUpdates([
            ParticipantSnapshot(
                sid: "PA_alice",
                identity: "alice",
                trackPublications: [
                    TrackPublicationSnapshot(sid: "TR_camera", name: "camera", kind: .video, source: .camera),
                ]
            ),
        ])

        let result = await actor.removeTrackPublication(sid: "TR_camera")
        let participant = result.0.remoteParticipants.first

        XCTAssertEqual(participant?.trackPublications.count, 0)
        XCTAssertEqual(result.1.count, 1)

        guard case let .trackUnpublished(publication, unpublishedParticipant) = result.1[0] else {
            return XCTFail("Expected trackUnpublished event.")
        }
        XCTAssertEqual(publication.sid, "TR_camera")
        XCTAssertEqual(unpublishedParticipant.sid, "PA_alice")
    }

    func testDisconnectedParticipantUpdateRemovesParticipantAndTracks() async {
        let actor = RoomActor(localParticipant: LocalParticipant(identity: "me"))
        _ = await actor.applyParticipantUpdates([
            ParticipantSnapshot(
                sid: "PA_alice",
                identity: "alice",
                trackPublications: [
                    TrackPublicationSnapshot(sid: "TR_camera", name: "camera", kind: .video, source: .camera),
                ]
            ),
        ])

        let result = await actor.applyParticipantUpdates([
            ParticipantSnapshot(sid: "PA_alice", identity: "alice", isDisconnected: true),
        ])

        XCTAssertEqual(result.0.remoteParticipants.count, 0)
        XCTAssertEqual(result.1.count, 2)

        guard case let .trackUnpublished(publication, participant) = result.1[0] else {
            return XCTFail("Expected trackUnpublished before participantDisconnected.")
        }
        XCTAssertEqual(publication.sid, "TR_camera")
        XCTAssertEqual(participant.sid, "PA_alice")

        guard case let .participantDisconnected(disconnectedParticipant) = result.1[1] else {
            return XCTFail("Expected participantDisconnected event.")
        }
        XCTAssertEqual(disconnectedParticipant.sid, "PA_alice")
    }

    func testDataEventMapsPacketSenderToRemoteParticipant() async {
        let actor = RoomActor(localParticipant: LocalParticipant(identity: "me"))
        _ = await actor.applyParticipantUpdates([
            ParticipantSnapshot(sid: "PA_alice", identity: "alice"),
        ])

        let event = await actor.dataEvent(for: ReceivedLiveKitDataPacket(
            payload: Data("hello".utf8),
            topic: "chat",
            reliability: .reliable,
            participantSid: "PA_alice",
            participantIdentity: nil
        ))

        guard case let .dataReceived(payload, participant, topic) = event else {
            return XCTFail("Expected dataReceived event.")
        }

        XCTAssertEqual(payload, Data("hello".utf8))
        XCTAssertEqual(participant?.identity, "alice")
        XCTAssertEqual(topic, "chat")
    }
}
