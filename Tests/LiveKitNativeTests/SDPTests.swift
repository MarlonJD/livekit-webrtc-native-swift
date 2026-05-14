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

    func testRejectsMalformedLines() {
        XCTAssertThrowsError(try SDPSessionDescription(parsing: "v=0\nthis-is-not-valid\n")) { error in
            XCTAssertEqual(error as? SDPParseError, .malformedLine("this-is-not-valid"))
        }
    }
}
