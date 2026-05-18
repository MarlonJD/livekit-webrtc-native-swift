import Foundation

package enum PublisherSDPOfferError: Error, Equatable, Sendable {
    case missingPublishMedia
}

package struct PublisherSDPOfferTrack: Equatable, Sendable {
    package var trackID: String
    package var kind: RTPMediaKind
    package var codec: RTPCodec
    package var payloadType: UInt8
    package var clockRate: Int
    package var channels: Int?
    package var ssrc: UInt32
    package var streamID: String

    package init(
        trackID: String,
        kind: RTPMediaKind,
        codec: RTPCodec,
        payloadType: UInt8,
        clockRate: Int,
        channels: Int? = nil,
        ssrc: UInt32,
        streamID: String = "livekit"
    ) {
        self.trackID = trackID
        self.kind = kind
        self.codec = codec
        self.payloadType = payloadType
        self.clockRate = clockRate
        self.channels = channels
        self.ssrc = ssrc
        self.streamID = streamID
    }

    package func withTrackID(_ trackID: String) -> PublisherSDPOfferTrack {
        var copy = self
        copy.trackID = trackID
        return copy
    }
}

package struct PublisherSDPOfferFactory: Sendable {
    package var mediaProfile: NativeWebRTCMediaProfile
    package var iceCredentials: ICECredentials
    package var dtlsFingerprint: DTLSSignature

    package init(
        mediaProfile: NativeWebRTCMediaProfile = .liveKitTiny,
        iceCredentials: ICECredentials = .random(),
        dtlsFingerprint: DTLSSignature = .random()
    ) {
        self.mediaProfile = mediaProfile
        self.iceCredentials = iceCredentials
        self.dtlsFingerprint = dtlsFingerprint
    }

    package func makeOffer(for tracks: [PublisherSDPOfferTrack]) throws -> String {
        let mediaOfferSections = tracks.enumerated().compactMap { index, track in
            offerSection(for: track, mid: "\(index)")
        }

        guard !mediaOfferSections.isEmpty else {
            throw PublisherSDPOfferError.missingPublishMedia
        }

        let offerSections = mediaOfferSections + [applicationOfferSection(mid: "data")]
        var offerLines: [SDPLine] = [
            SDPLine(field: "v", value: "0"),
            SDPLine(field: "o", value: "- 0 0 IN IP4 127.0.0.1"),
            SDPLine(field: "s", value: "-"),
            SDPLine(field: "t", value: "0 0"),
            SDPLine(field: "a", value: "ice-ufrag:\(iceCredentials.usernameFragment)"),
            SDPLine(field: "a", value: "ice-pwd:\(iceCredentials.password)"),
            SDPLine(field: "a", value: "fingerprint:\(dtlsFingerprint.hashFunction) \(dtlsFingerprint.value)"),
            SDPLine(field: "a", value: "ice-options:trickle"),
            SDPLine(field: "a", value: "setup:actpass"),
            SDPLine(field: "a", value: "group:BUNDLE \(offerSections.compactMap(\.mid).joined(separator: " "))"),
            SDPLine(field: "a", value: "msid-semantic: WMS *"),
        ]

        for section in offerSections {
            offerLines.append(SDPLine(field: "m", value: section.mediaLine))
            offerLines.append(contentsOf: section.attributes.map { SDPLine(field: "a", value: $0) })
        }

        return try SDPSessionDescription(lines: offerLines).serialized()
    }

    private func offerSection(for track: PublisherSDPOfferTrack, mid: String) -> SDPMediaSection? {
        switch track.kind {
        case .audio:
            guard mediaProfile.publishAudioCodecs.contains(track.codec) else {
                return nil
            }
        case .video:
            guard mediaProfile.publishVideoCodecs.contains(track.codec) else {
                return nil
            }
        case .application:
            return nil
        }

        let payloadType = String(track.payloadType)
        var attributes = [
            "mid:\(mid)",
            "setup:actpass",
            "sendonly",
            "rtcp-mux",
            rtpMapAttribute(for: track),
        ]

        attributes.append(contentsOf: codecParameters(for: track, payloadType: payloadType))
        attributes.append("ssrc:\(track.ssrc) cname:\(track.streamID)")
        attributes.append("msid:\(track.streamID) \(track.trackID)")

        return SDPMediaSection(
            mediaLine: "\(track.kind.rawValue) 9 UDP/TLS/RTP/SAVPF \(payloadType)",
            attributes: attributes
        )
    }

    private func applicationOfferSection(mid: String) -> SDPMediaSection {
        SDPMediaSection(
            mediaLine: "application 9 UDP/DTLS/SCTP \(mediaProfile.dataChannelCodec.rawValue)",
            attributes: [
                "mid:\(mid)",
                "setup:actpass",
                "sctp-port:\(SCTPAssociationConfiguration.webRTCDataChannelPort)",
            ]
        )
    }

    private func rtpMapAttribute(for track: PublisherSDPOfferTrack) -> String {
        let payloadType = String(track.payloadType)
        let codecDescriptor: String
        if let channels = track.channels {
            codecDescriptor = "\(track.codec.rawValue)/\(track.clockRate)/\(channels)"
        } else {
            codecDescriptor = "\(track.codec.rawValue)/\(track.clockRate)"
        }

        return "rtpmap:\(payloadType) \(codecDescriptor)"
    }

    private func codecParameters(for track: PublisherSDPOfferTrack, payloadType: String) -> [String] {
        switch track.codec {
        case .h264:
            return [
                "fmtp:\(payloadType) level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
                "rtcp-fb:\(payloadType) nack",
                "rtcp-fb:\(payloadType) nack pli",
            ]
        case .vp8:
            return [
                "rtcp-fb:\(payloadType) nack",
                "rtcp-fb:\(payloadType) nack pli",
            ]
        case .opus:
            return ["fmtp:\(payloadType) minptime=10;useinbandfec=1"]
        case .webRTCDataChannel:
            return []
        }
    }
}
