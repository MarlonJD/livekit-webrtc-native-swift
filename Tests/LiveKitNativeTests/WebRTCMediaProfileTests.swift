import XCTest
@testable import LiveKitNativeWebRTC

final class WebRTCMediaProfileTests: XCTestCase {
    func testTinyProfilePublishesH264AndReceivesH264PlusVP8() {
        let profile = NativeWebRTCMediaProfile.liveKitTiny

        XCTAssertEqual(profile.publishVideoCodecs, [.h264])
        XCTAssertEqual(profile.receiveVideoCodecs, [.h264, .vp8])
        XCTAssertEqual(profile.publishAudioCodecs, [.opus])
        XCTAssertEqual(profile.receiveAudioCodecs, [.opus])
        XCTAssertEqual(profile.dataChannelCodec, .webRTCDataChannel)
    }

    func testPeerConnectionCapabilitiesPreferTinyPublishProfile() {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .publisher))

        XCTAssertEqual(
            coordinator.localCapabilities,
            [
                SDPCodecCapability(kind: .audio, codec: .opus, clockRate: 48_000, channels: 1),
                SDPCodecCapability(kind: .video, codec: .h264, clockRate: 90_000),
                SDPCodecCapability(kind: .application, codec: .webRTCDataChannel, clockRate: 0),
            ]
        )
    }
}
