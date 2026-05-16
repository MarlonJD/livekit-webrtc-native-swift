package enum SubscribeRTCPFeedbackSignal: Equatable, Sendable {
    case h264RTPError(H264RTPError)
    case vp8RTPError(VP8RTPError)
    case missingSequenceNumbers([UInt16])
    case keyFrameRequest
}

package struct SubscribeRTCPFeedbackPlanner: Equatable, Sendable {
    package static let maximumMissingSequenceNumbers = 512

    package var feedbackPolicy: RTCPFeedbackPolicy

    package init(feedbackPolicy: RTCPFeedbackPolicy = RTCPFeedbackPolicy()) {
        self.feedbackPolicy = feedbackPolicy
    }

    package func feedbackPackets(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        signals: [SubscribeRTCPFeedbackSignal]
    ) -> [RTCPPacket] {
        var missingSequenceNumbers: [UInt16] = []
        var requestsKeyFrame = false

        for signal in signals {
            switch signal {
            case let .h264RTPError(error):
                missingSequenceNumbers.append(contentsOf: Self.missingSequenceNumbers(for: error))
            case let .vp8RTPError(error):
                missingSequenceNumbers.append(contentsOf: Self.missingSequenceNumbers(for: error))
            case let .missingSequenceNumbers(sequenceNumbers):
                missingSequenceNumbers.append(contentsOf: sequenceNumbers)
            case .keyFrameRequest:
                requestsKeyFrame = true
            }
        }

        return feedbackPolicy.feedbackPackets(
            senderSSRC: senderSSRC,
            mediaSSRC: mediaSSRC,
            missingSequenceNumbers: missingSequenceNumbers,
            requestsKeyFrame: requestsKeyFrame
        )
    }

    package func feedbackPackets(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        missingSequenceNumbers: [UInt16] = [],
        requestsKeyFrame: Bool = false
    ) -> [RTCPPacket] {
        feedbackPolicy.feedbackPackets(
            senderSSRC: senderSSRC,
            mediaSSRC: mediaSSRC,
            missingSequenceNumbers: missingSequenceNumbers,
            requestsKeyFrame: requestsKeyFrame
        )
    }

    package func feedbackPackets(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        h264Error: H264RTPError,
        requestsKeyFrame: Bool = false
    ) -> [RTCPPacket] {
        feedbackPackets(
            senderSSRC: senderSSRC,
            mediaSSRC: mediaSSRC,
            signals: [.h264RTPError(h264Error)] + (requestsKeyFrame ? [.keyFrameRequest] : [])
        )
    }

    package func feedbackPackets(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        vp8Error: VP8RTPError,
        requestsKeyFrame: Bool = false
    ) -> [RTCPPacket] {
        feedbackPackets(
            senderSSRC: senderSSRC,
            mediaSSRC: mediaSSRC,
            signals: [.vp8RTPError(vp8Error)] + (requestsKeyFrame ? [.keyFrameRequest] : [])
        )
    }

    private static func missingSequenceNumbers(for error: H264RTPError) -> [UInt16] {
        guard case let .sequenceNumberGap(expected, actual) = error else {
            return []
        }

        return missingSequenceNumbers(expected: expected, actual: actual)
    }

    private static func missingSequenceNumbers(for error: VP8RTPError) -> [UInt16] {
        guard case let .sequenceNumberGap(expected, actual) = error else {
            return []
        }

        return missingSequenceNumbers(expected: expected, actual: actual)
    }

    private static func missingSequenceNumbers(expected: UInt16, actual: UInt16) -> [UInt16] {
        let forwardDistance = Int(actual &- expected)
        guard forwardDistance > 0,
              forwardDistance <= Int(UInt16.max / 2)
        else {
            return []
        }

        var sequenceNumbers: [UInt16] = []
        let missingCount = min(forwardDistance, maximumMissingSequenceNumbers)
        sequenceNumbers.reserveCapacity(missingCount)

        var sequenceNumber = expected
        for _ in 0..<missingCount {
            sequenceNumbers.append(sequenceNumber)
            sequenceNumber &+= 1
        }

        return sequenceNumbers
    }
}
