import XCTest
@testable import LiveKitNative
@testable import LiveKitNativeWebRTC

final class LocalAudioPublishPlanTests: XCTestCase {
    func testAudioTrackCarriesNativeMicrophoneConfiguration() throws {
        let track = try LocalAudioTrack.createTrack(
            options: AudioCaptureOptions(
                echoCancellation: false,
                sampleRate: 48_000,
                channelCount: 2,
                frameDurationMilliseconds: 20
            )
        )

        XCTAssertEqual(track.name, "microphone")
        XCTAssertEqual(track.source, .microphone)
        XCTAssertEqual(track.audioCaptureOptions?.echoCancellation, false)
        XCTAssertEqual(track.audioCaptureOptions?.sampleRate, 48_000)
        XCTAssertEqual(track.audioCaptureOptions?.channelCount, 2)
        XCTAssertEqual(track.nativeMicrophoneSource?.configuration.echoCancellation, false)
        XCTAssertEqual(track.nativeMicrophoneSource?.configuration.sampleRate, 48_000)
        XCTAssertEqual(track.nativeMicrophoneSource?.configuration.channelCount, 2)
        XCTAssertEqual(track.nativeMicrophoneSource?.configuration.frameDurationMilliseconds, 20)
    }

    func testLocalAudioPublishPlanBuildsOpusAddTrackRequest() throws {
        let track = try LocalAudioTrack.createTrack(
            options: AudioCaptureOptions(sampleRate: 48_000, channelCount: 2, frameDurationMilliseconds: 20)
        )
        let plan = LocalAudioPublishPlan(
            track: track,
            options: TrackPublishOptions(name: "main-mic", source: .microphone),
            ssrc: 5_678,
            payloadType: 111
        )
        let request = plan.addTrackRequest

        XCTAssertEqual(request.cid, track.id)
        XCTAssertEqual(request.name, "main-mic")
        XCTAssertEqual(request.type, .audio)
        XCTAssertEqual(request.source, .microphone)
        XCTAssertTrue(request.stereo)
        XCTAssertFalse(request.disableDtx)
        XCTAssertTrue(request.disableRed)
        XCTAssertEqual(plan.codec, .opus)
        XCTAssertEqual(plan.sampleRate, 48_000)
        XCTAssertEqual(plan.channelCount, 2)
        XCTAssertEqual(plan.frameDurationMilliseconds, 20)

        let rtpPacket = plan.packetizer.packetize(try OpusPacket(payload: Data([0x08, 0xAA])))
        XCTAssertEqual(rtpPacket.payloadType, 111)
        XCTAssertEqual(rtpPacket.ssrc, 5_678)
    }
}
