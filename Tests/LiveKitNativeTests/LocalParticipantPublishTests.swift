import XCTest
@testable import LiveKitNative

final class LocalParticipantPublishTests: XCTestCase {
    func testPublishVideoTrackCreatesLocalPublication() async throws {
        let participant = LocalParticipant(identity: "me")
        let track = try LocalVideoTrack.createCameraTrack(
            options: CameraCaptureOptions(width: 1_280, height: 720, framesPerSecond: 30)
        )

        let publication = try await participant.publish(
            videoTrack: track,
            options: TrackPublishOptions(name: "camera-main", source: .camera)
        )

        XCTAssertEqual(publication.sid, track.id)
        XCTAssertEqual(publication.name, "camera-main")
        XCTAssertEqual(publication.kind, .video)
        XCTAssertEqual(publication.source, .camera)
        XCTAssertEqual(publication.track as? LocalVideoTrack, track)
        XCTAssertEqual(participant.trackPublications, [publication])
    }

    func testSetCameraEnabledIsIdempotentAndDisableRemovesPublication() async throws {
        let participant = LocalParticipant(identity: "me")

        try await participant.setCamera(enabled: true, options: CameraCaptureOptions(width: 640, height: 360))
        try await participant.setCamera(enabled: true, options: CameraCaptureOptions(width: 640, height: 360))

        XCTAssertEqual(participant.trackPublications.count, 1)
        XCTAssertEqual(participant.trackPublications.first?.source, .camera)

        try await participant.setCamera(enabled: false)

        XCTAssertEqual(participant.trackPublications.count, 0)
    }

    func testPublishAudioTrackCreatesLocalPublication() async throws {
        let participant = LocalParticipant(identity: "me")
        let track = try LocalAudioTrack.createTrack(
            options: AudioCaptureOptions(sampleRate: 48_000, channelCount: 1, frameDurationMilliseconds: 20)
        )

        let publication = try await participant.publish(
            audioTrack: track,
            options: TrackPublishOptions(name: "mic-main", source: .microphone)
        )

        XCTAssertEqual(publication.sid, track.id)
        XCTAssertEqual(publication.name, "mic-main")
        XCTAssertEqual(publication.kind, .audio)
        XCTAssertEqual(publication.source, .microphone)
        XCTAssertEqual(publication.track as? LocalAudioTrack, track)
        XCTAssertEqual(participant.trackPublications, [publication])
    }

    func testSetMicrophoneEnabledIsIdempotentAndDisableRemovesPublication() async throws {
        let participant = LocalParticipant(identity: "me")

        try await participant.setMicrophone(enabled: true)
        try await participant.setMicrophone(enabled: true)

        XCTAssertEqual(participant.trackPublications.count, 1)
        XCTAssertEqual(participant.trackPublications.first?.source, .microphone)

        try await participant.setMicrophone(enabled: false)

        XCTAssertEqual(participant.trackPublications.count, 0)
    }

    func testUnpublishRemovesLocalPublication() async throws {
        let participant = LocalParticipant(identity: "me")
        let track = try LocalVideoTrack.createCameraTrack()
        let publication = try await participant.publish(videoTrack: track)

        try await participant.unpublish(publication: publication)

        XCTAssertEqual(participant.trackPublications.count, 0)
    }
}
