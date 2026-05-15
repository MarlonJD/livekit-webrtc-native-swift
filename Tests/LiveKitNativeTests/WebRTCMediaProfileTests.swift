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

    func testDTLSFingerprintUsesSHA256ColonSeparatedFormat() {
        let fingerprint = DTLSSignature.sha256Fingerprint(for: Data("livekit-native".utf8))

        XCTAssertEqual(fingerprint.hashFunction, "sha-256")
        XCTAssertEqual(fingerprint.value.split(separator: ":").count, 32)
        XCTAssertTrue(fingerprint.value.allSatisfy { character in
            character == ":" || character.isHexDigit
        })
    }

    func testDefaultPeerConnectionConfigurationHasDTLSFingerprint() {
        let configuration = NativeWebRTCConfiguration(role: .subscriber)

        XCTAssertEqual(configuration.dtlsFingerprint.hashFunction, "sha-256")
        XCTAssertEqual(configuration.dtlsFingerprint.value.split(separator: ":").count, 32)
    }

    func testPeerConnectionBuildsChecklistFromParsedRemoteICECandidates() throws {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .subscriber))
        try coordinator.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:remote 1 UDP 1694498815 203.0.113.9 6000 typ srflx","sdpMid":"0","sdpMLineIndex":0}"#,
            isFinal: false
        )
        let local = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 5000,
            type: .host
        )

        let checklist = coordinator.makeCandidateChecklist(
            localCandidates: [local],
            isControlling: false
        )

        XCTAssertEqual(coordinator.parsedRemoteICECandidates.count, 1)
        XCTAssertEqual(checklist.pairs.count, 1)
        XCTAssertEqual(checklist.pairs.first?.remote.address, "203.0.113.9")
    }
}
