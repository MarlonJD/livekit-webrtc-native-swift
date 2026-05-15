import XCTest
@testable import LiveKitNativeWebRTC

final class SDPTests: XCTestCase {
    func testParsesBundleMIDsMediaSectionsAndCodecs() throws {
        let sdp = """
        v=0
        o=- 4611731400430051336 2 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 data
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        m=video 9 UDP/TLS/RTP/SAVPF 102 96
        a=mid:1
        a=rtcp-mux
        a=rtpmap:102 H264/90000
        a=rtpmap:96 VP8/90000
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        a=mid:data
        a=sctp-port:5000
        """

        let description = try SDPSessionDescription(parsing: sdp)

        XCTAssertEqual(description.bundleMIDs, ["0", "1", "data"])
        XCTAssertEqual(description.mediaSections.map(\.mid), ["0", "1", "data"])
        XCTAssertEqual(description.mediaSections[0].codecNames, ["opus"])
        XCTAssertEqual(description.mediaSections[1].codecNames, ["H264", "VP8"])
        XCTAssertTrue(description.mediaSections[0].hasRTCPMux)
        XCTAssertTrue(description.mediaSections[1].hasRTCPMux)
    }

    func testSerializesWithCRLFTerminator() throws {
        let description = try SDPSessionDescription(parsing: "v=0\ns=-\nt=0 0\n")

        XCTAssertEqual(description.serialized(), "v=0\r\ns=-\r\nt=0 0\r\n")
    }

    func testExtractsSessionLevelICECredentials() throws {
        let description = try SDPSessionDescription(parsing: """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        """)

        XCTAssertEqual(
            description.iceCredentials,
            ICECredentials(usernameFragment: "remote-ufrag", password: "remote-password")
        )
    }

    func testExtractsSessionLevelDTLSFingerprintAndSetupRole() throws {
        let description = try SDPSessionDescription(parsing: """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=fingerprint:sha-256 AA:BB:CC
        a=setup:actpass
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        """)

        XCTAssertEqual(
            description.dtlsFingerprint,
            DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        )
        XCTAssertEqual(description.dtlsSetupRole, .actpass)
    }

    func testRejectsMalformedLines() {
        XCTAssertThrowsError(try SDPSessionDescription(parsing: "v=0\nthis-is-not-valid\n")) { error in
            XCTAssertEqual(error as? SDPParseError, .malformedLine("this-is-not-valid"))
        }
    }

    func testSubscriberAnswerKeepsSupportedReceiveCodecsAndBundleMids() throws {
        let offer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 data
        m=audio 9 UDP/TLS/RTP/SAVPF 111 63
        a=mid:0
        a=setup:actpass
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        a=rtpmap:63 red/48000/2
        m=video 9 UDP/TLS/RTP/SAVPF 102 96 35
        a=mid:1
        a=setup:actpass
        a=rtcp-mux
        a=rtpmap:102 H264/90000
        a=rtpmap:96 VP8/90000
        a=rtpmap:35 AV1/90000
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        a=mid:data
        a=setup:actpass
        a=sctp-port:5000
        """

        let answer = try SubscriberSDPAnswerFactory().makeAnswer(to: offer)
        let parsedAnswer = try SDPSessionDescription(parsing: answer)

        XCTAssertEqual(parsedAnswer.bundleMIDs, ["0", "1", "data"])
        XCTAssertEqual(parsedAnswer.mediaSections.map(\.mid), ["0", "1", "data"])
        XCTAssertEqual(parsedAnswer.mediaSections[0].mediaLine, "audio 9 UDP/TLS/RTP/SAVPF 111")
        XCTAssertEqual(parsedAnswer.mediaSections[1].mediaLine, "video 9 UDP/TLS/RTP/SAVPF 102 96")
        XCTAssertEqual(parsedAnswer.mediaSections[2].mediaLine, "application 9 UDP/DTLS/SCTP webrtc-datachannel")
        XCTAssertTrue(parsedAnswer.mediaSections[0].attributes.contains("recvonly"))
        XCTAssertTrue(parsedAnswer.mediaSections[1].attributes.contains("recvonly"))
        XCTAssertTrue(parsedAnswer.mediaSections[0].attributes.contains("setup:active"))
        XCTAssertFalse(answer.contains("AV1/90000"))
        XCTAssertFalse(answer.contains("red/48000/2"))
    }

    func testSubscriberAnswerIncludesNegotiationLines() throws {
        let offer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=setup:actpass
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        """

        let credentials = ICECredentials(
            usernameFragment: "ufrag-fixed",
            password: "pwd-fixed-value"
        )
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")

        let answer = try SubscriberSDPAnswerFactory(
            iceCredentials: credentials,
            dtlsFingerprint: fingerprint
        ).makeAnswer(to: offer)

        XCTAssertTrue(answer.contains("a=ice-ufrag:ufrag-fixed"))
        XCTAssertTrue(answer.contains("a=ice-pwd:pwd-fixed-value"))
        XCTAssertTrue(answer.contains("a=fingerprint:sha-256 AA:BB:CC"))
        XCTAssertTrue(answer.contains("a=ice-options:trickle"))
    }
}
