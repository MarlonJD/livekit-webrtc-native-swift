import XCTest
@testable import LiveKitNative

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
}
