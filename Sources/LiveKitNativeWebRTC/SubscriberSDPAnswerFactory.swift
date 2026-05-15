import Foundation

package enum SubscriberSDPAnswerError: Error, Equatable, Sendable {
    case missingSupportedMedia
}

package struct SubscriberSDPAnswerFactory: Sendable {
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

    package func makeAnswer(to offerSDP: String) throws -> String {
        let offer = try SDPSessionDescription(parsing: offerSDP)
        var answerLines: [SDPLine] = [
            SDPLine(field: "v", value: "0"),
            SDPLine(field: "o", value: "- 0 0 IN IP4 127.0.0.1"),
            SDPLine(field: "s", value: "-"),
            SDPLine(field: "t", value: "0 0"),
        ]

        answerLines.append(SDPLine(field: "a", value: "ice-ufrag:\(iceCredentials.usernameFragment)"))
        answerLines.append(SDPLine(field: "a", value: "ice-pwd:\(iceCredentials.password)"))
        answerLines.append(SDPLine(field: "a", value: "fingerprint:\(dtlsFingerprint.hashFunction) \(dtlsFingerprint.value)"))
        answerLines.append(SDPLine(field: "a", value: "ice-options:trickle"))
        let answerSections = offer.mediaSections.compactMap { answerSection(for: $0) }
        guard !answerSections.isEmpty else {
            throw SubscriberSDPAnswerError.missingSupportedMedia
        }

        let bundleMIDs = answerSections.compactMap(\.mid)
        if !bundleMIDs.isEmpty {
            answerLines.append(SDPLine(field: "a", value: "group:BUNDLE \(bundleMIDs.joined(separator: " "))"))
        }

        answerLines.append(SDPLine(field: "a", value: "msid-semantic: WMS *"))

        for section in answerSections {
            answerLines.append(SDPLine(field: "m", value: section.mediaLine))
            answerLines.append(contentsOf: section.attributes.map { SDPLine(field: "a", value: $0) })
        }

        return try SDPSessionDescription(lines: answerLines).serialized()
    }

    private func answerSection(for offerSection: SDPMediaSection) -> SDPMediaSection? {
        guard let kind = offerSection.kind else {
            return nil
        }

        switch kind {
        case .audio, .video:
            return rtpAnswerSection(for: offerSection, kind: kind)
        case .application:
            return applicationAnswerSection(for: offerSection)
        }
    }

    private func rtpAnswerSection(for offerSection: SDPMediaSection, kind: RTPMediaKind) -> SDPMediaSection? {
        let supportedCodecs = supportedReceiveCodecs(for: kind)
        let acceptedPayloadTypes = offerSection.rtpMapEntries
            .filter { supportedCodecs.contains($0.codec) }
            .map(\.payloadType)

        guard !acceptedPayloadTypes.isEmpty else {
            return nil
        }

        let mediaLine = offerSection.answerMediaLine(with: acceptedPayloadTypes)
        var attributes = commonAnswerAttributes(from: offerSection)
        attributes.append("recvonly")
        attributes.append(contentsOf: offerSection.codecAttributes(for: acceptedPayloadTypes))

        return SDPMediaSection(mediaLine: mediaLine, attributes: attributes)
    }

    private func applicationAnswerSection(for offerSection: SDPMediaSection) -> SDPMediaSection? {
        guard offerSection.mediaLine.contains(mediaProfile.dataChannelCodec.rawValue) else {
            return nil
        }

        var attributes = commonAnswerAttributes(from: offerSection)
        attributes.append(contentsOf: offerSection.attributes.filter { $0.hasPrefix("sctp-port:") })

        return SDPMediaSection(mediaLine: offerSection.answerMediaLine(with: offerSection.payloadTokens), attributes: attributes)
    }

    private func commonAnswerAttributes(from offerSection: SDPMediaSection) -> [String] {
        var attributes: [String] = []

        if let mid = offerSection.mid {
            attributes.append("mid:\(mid)")
        }

        if offerSection.attributes.contains(where: { $0.hasPrefix("setup:") }) {
            attributes.append("setup:active")
        }

        if offerSection.hasRTCPMux {
            attributes.append("rtcp-mux")
        }

        return attributes
    }

    private func supportedReceiveCodecs(for kind: RTPMediaKind) -> Set<RTPCodec> {
        switch kind {
        case .audio:
            Set(mediaProfile.receiveAudioCodecs)
        case .video:
            Set(mediaProfile.receiveVideoCodecs)
        case .application:
            [mediaProfile.dataChannelCodec]
        }
    }
}

private struct RTPMapEntry: Equatable, Sendable {
    var payloadType: String
    var codec: RTPCodec
}

private extension SDPMediaSection {
    var kind: RTPMediaKind? {
        mediaLine.split(separator: " ").first.flatMap { RTPMediaKind(rawValue: String($0)) }
    }

    var payloadTokens: [String] {
        Array(mediaLine.split(separator: " ").dropFirst(3).map(String.init))
    }

    var rtpMapEntries: [RTPMapEntry] {
        attributes.compactMap { attribute in
            guard attribute.hasPrefix("rtpmap:") else {
                return nil
            }

            let mapping = attribute.dropFirst("rtpmap:".count)
            guard let codecStart = mapping.firstIndex(of: " ") else {
                return nil
            }

            let payloadType = String(mapping[..<codecStart])
            let codecDescriptor = mapping[mapping.index(after: codecStart)...]
            guard let codecName = codecDescriptor.split(separator: "/", maxSplits: 1).first else {
                return nil
            }

            return RTPCodec(sdpCodecName: String(codecName)).map {
                RTPMapEntry(payloadType: payloadType, codec: $0)
            }
        }
    }

    func answerMediaLine(with payloadTypes: [String]) -> String {
        let tokens = mediaLine.split(separator: " ").map(String.init)
        guard tokens.count >= 3 else {
            return mediaLine
        }

        return (Array(tokens.prefix(3)) + payloadTypes).joined(separator: " ")
    }

    func codecAttributes(for payloadTypes: [String]) -> [String] {
        attributes.filter { attribute in
            guard
                attribute.hasPrefix("rtpmap:") ||
                attribute.hasPrefix("fmtp:") ||
                attribute.hasPrefix("rtcp-fb:")
            else {
                return false
            }

            return payloadTypes.contains { payloadType in
                attribute.hasPrefix("rtpmap:\(payloadType) ") ||
                attribute.hasPrefix("fmtp:\(payloadType) ") ||
                attribute.hasPrefix("rtcp-fb:\(payloadType) ")
            }
        }
    }
}

private extension RTPCodec {
    init?(sdpCodecName: String) {
        switch sdpCodecName.lowercased() {
        case "h264":
            self = .h264
        case "vp8":
            self = .vp8
        case "opus":
            self = .opus
        case "webrtc-datachannel":
            self = .webRTCDataChannel
        default:
            return nil
        }
    }
}
