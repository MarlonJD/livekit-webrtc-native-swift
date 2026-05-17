import Foundation

package struct RTPJitterBufferInsertResult: Equatable, Sendable {
    package var releasedPackets: [RTPPacket]
    package var droppedSequenceNumbers: [UInt16]
    package var missingSequenceNumbers: [UInt16]

    package init(
        releasedPackets: [RTPPacket] = [],
        droppedSequenceNumbers: [UInt16] = [],
        missingSequenceNumbers: [UInt16] = []
    ) {
        self.releasedPackets = releasedPackets
        self.droppedSequenceNumbers = droppedSequenceNumbers
        self.missingSequenceNumbers = missingSequenceNumbers
    }
}

package struct RTPJitterBuffer: Sendable {
    private let maxBufferedPackets: Int
    private var nextExpectedSequenceNumber: UInt16?
    private var bufferedPackets: [UInt16: RTPPacket]

    package init(maxBufferedPackets: Int) {
        precondition(maxBufferedPackets >= 0, "maxBufferedPackets must be non-negative")

        self.maxBufferedPackets = maxBufferedPackets
        nextExpectedSequenceNumber = nil
        bufferedPackets = [:]
    }

    package mutating func insert(_ packet: RTPPacket) -> RTPJitterBufferInsertResult {
        if nextExpectedSequenceNumber == nil {
            nextExpectedSequenceNumber = packet.sequenceNumber
        }

        guard let nextExpectedSequenceNumber else {
            return RTPJitterBufferInsertResult()
        }

        if Self.isOlder(packet.sequenceNumber, than: nextExpectedSequenceNumber) {
            return RTPJitterBufferInsertResult(droppedSequenceNumbers: [packet.sequenceNumber])
        }

        if bufferedPackets[packet.sequenceNumber] != nil {
            return RTPJitterBufferInsertResult(droppedSequenceNumbers: [packet.sequenceNumber])
        }

        bufferedPackets[packet.sequenceNumber] = packet

        var result = RTPJitterBufferInsertResult()
        result.releasedPackets.append(contentsOf: releaseContiguousPackets())

        while bufferedPackets.count > maxBufferedPackets {
            guard let skippedResult = skipNextGap() else {
                break
            }

            result.missingSequenceNumbers.append(contentsOf: skippedResult.missingSequenceNumbers)
            result.releasedPackets.append(contentsOf: skippedResult.releasedPackets)
        }

        return result
    }

    package mutating func flush() -> [RTPPacket] {
        let packets: [RTPPacket]

        if let nextExpectedSequenceNumber {
            packets = bufferedPackets.values.sorted {
                Self.forwardDistance(from: nextExpectedSequenceNumber, to: $0.sequenceNumber) <
                    Self.forwardDistance(from: nextExpectedSequenceNumber, to: $1.sequenceNumber)
            }
        } else {
            packets = bufferedPackets.values.sorted { $0.sequenceNumber < $1.sequenceNumber }
        }

        bufferedPackets.removeAll(keepingCapacity: true)
        nextExpectedSequenceNumber = nil
        return packets
    }

    private mutating func releaseContiguousPackets() -> [RTPPacket] {
        var releasedPackets: [RTPPacket] = []

        while let expectedSequenceNumber = nextExpectedSequenceNumber,
              let packet = bufferedPackets.removeValue(forKey: expectedSequenceNumber) {
            releasedPackets.append(packet)
            nextExpectedSequenceNumber = expectedSequenceNumber &+ 1
        }

        return releasedPackets
    }

    private mutating func skipNextGap() -> RTPJitterBufferInsertResult? {
        guard let nextExpectedSequenceNumber,
              let nextBufferedSequenceNumber = bufferedPackets.keys.min(by: {
                  Self.forwardDistance(from: nextExpectedSequenceNumber, to: $0) <
                      Self.forwardDistance(from: nextExpectedSequenceNumber, to: $1)
              }) else {
            return nil
        }

        let missingSequenceNumbers = Self.sequenceNumbers(
            from: nextExpectedSequenceNumber,
            upTo: nextBufferedSequenceNumber
        )

        self.nextExpectedSequenceNumber = nextBufferedSequenceNumber

        return RTPJitterBufferInsertResult(
            releasedPackets: releaseContiguousPackets(),
            missingSequenceNumbers: missingSequenceNumbers
        )
    }

    private static func isOlder(_ sequenceNumber: UInt16, than expectedSequenceNumber: UInt16) -> Bool {
        let distance = forwardDistance(from: expectedSequenceNumber, to: sequenceNumber)
        return distance >= 0x8000
    }

    private static func forwardDistance(from sequenceNumber: UInt16, to otherSequenceNumber: UInt16) -> UInt16 {
        otherSequenceNumber &- sequenceNumber
    }

    private static func sequenceNumbers(from start: UInt16, upTo end: UInt16) -> [UInt16] {
        var sequenceNumbers: [UInt16] = []
        var sequenceNumber = start

        while sequenceNumber != end {
            sequenceNumbers.append(sequenceNumber)
            sequenceNumber = sequenceNumber &+ 1
        }

        return sequenceNumbers
    }
}
