import Foundation

package struct RTCPReceiverReportSnapshot: Equatable, Sendable {
    package var mediaSSRC: UInt32
    package var expectedPackets: UInt32
    package var receivedPackets: UInt32
    package var report: RTCPReceptionReport

    package init(
        mediaSSRC: UInt32,
        expectedPackets: UInt32,
        receivedPackets: UInt32,
        report: RTCPReceptionReport
    ) {
        self.mediaSSRC = mediaSSRC
        self.expectedPackets = expectedPackets
        self.receivedPackets = receivedPackets
        self.report = report
    }
}

package struct RTCPReceiverReportTracker: Sendable {
    private var baseSequenceNumber: UInt16?
    private var highestSequenceNumber: UInt16?
    private var sequenceCycles: UInt32 = 0
    private var receivedPackets: UInt32 = 0
    private var previousExpectedPackets: UInt32 = 0
    private var previousReceivedPackets: UInt32 = 0
    private var previousTransit: Int64?
    private var jitter: Double = 0
    private var lastSenderReport: UInt32 = 0
    private var lastSenderReportReceivedAt: TimeInterval?

    package init() {}

    package mutating func observe(_ packet: RTPPacket, arrivalRTPTime: UInt32? = nil) {
        observeSequenceNumber(packet.sequenceNumber)
        receivedPackets &+= 1

        let arrival = arrivalRTPTime ?? packet.timestamp
        let transit = Int64(arrival) - Int64(packet.timestamp)
        if let previousTransit {
            let delta = abs(transit - previousTransit)
            jitter += (Double(delta) - jitter) / 16.0
        }
        previousTransit = transit
    }

    package mutating func observe(_ senderReport: RTCPSenderReport, receivedAt: TimeInterval) {
        lastSenderReport = UInt32((senderReport.ntpTimestamp >> 16) & 0xFFFF_FFFF)
        lastSenderReportReceivedAt = receivedAt
    }

    package mutating func report(mediaSSRC: UInt32, now: TimeInterval) -> RTCPReceiverReportSnapshot? {
        guard let baseSequenceNumber,
              let highestSequenceNumber
        else {
            return nil
        }

        let extendedHighestSequenceNumber = sequenceCycles + UInt32(highestSequenceNumber)
        let expectedPackets = extendedHighestSequenceNumber - UInt32(baseSequenceNumber) + 1
        let lostPackets = Int64(expectedPackets) - Int64(receivedPackets)
        let intervalExpectedPackets = expectedPackets - previousExpectedPackets
        let intervalReceivedPackets = receivedPackets - previousReceivedPackets
        let intervalLostPackets = Int64(intervalExpectedPackets) - Int64(intervalReceivedPackets)
        let fractionLost: UInt8
        if intervalExpectedPackets == 0 || intervalLostPackets <= 0 {
            fractionLost = 0
        } else {
            fractionLost = UInt8(min(255, (intervalLostPackets * 256) / Int64(intervalExpectedPackets)))
        }

        previousExpectedPackets = expectedPackets
        previousReceivedPackets = receivedPackets

        let report = RTCPReceptionReport(
            ssrc: mediaSSRC,
            fractionLost: fractionLost,
            cumulativePacketsLost: Self.clampedCumulativePacketsLost(lostPackets),
            highestSequenceNumber: extendedHighestSequenceNumber,
            jitter: UInt32(max(0, min(Double(UInt32.max), jitter.rounded(.down)))),
            lastSenderReport: lastSenderReport,
            delaySinceLastSenderReport: delaySinceLastSenderReport(now: now)
        )
        return RTCPReceiverReportSnapshot(
            mediaSSRC: mediaSSRC,
            expectedPackets: expectedPackets,
            receivedPackets: receivedPackets,
            report: report
        )
    }

    package func snapshot(mediaSSRC: UInt32, now: TimeInterval) -> RTCPReceiverReportSnapshot? {
        var copy = self
        return copy.report(mediaSSRC: mediaSSRC, now: now)
    }

    private mutating func observeSequenceNumber(_ sequenceNumber: UInt16) {
        guard let currentHighest = highestSequenceNumber else {
            baseSequenceNumber = sequenceNumber
            highestSequenceNumber = sequenceNumber
            return
        }

        if sequenceNumber < currentHighest, currentHighest &- sequenceNumber > 0x8000 {
            sequenceCycles &+= 0x1_0000
            highestSequenceNumber = sequenceNumber
        } else if Self.sequenceNumberIsNewer(sequenceNumber, than: currentHighest) {
            highestSequenceNumber = sequenceNumber
        }
    }

    private static func sequenceNumberIsNewer(_ lhs: UInt16, than rhs: UInt16) -> Bool {
        lhs != rhs && lhs &- rhs < 0x8000
    }

    private static func clampedCumulativePacketsLost(_ value: Int64) -> Int32 {
        Int32(max(-0x80_0000, min(0x7F_FFFF, value)))
    }

    private func delaySinceLastSenderReport(now: TimeInterval) -> UInt32 {
        guard let lastSenderReportReceivedAt else {
            return 0
        }

        let elapsedSeconds = max(0, now - lastSenderReportReceivedAt)
        return UInt32(min(Double(UInt32.max), (elapsedSeconds * 65_536).rounded(.down)))
    }
}

package final class RTCPReceiverReportStore: @unchecked Sendable {
    private let lock = NSLock()
    private var trackersBySSRC: [UInt32: RTCPReceiverReportTracker] = [:]

    package init() {}

    @discardableResult
    package func observe(_ packet: RTPPacket, arrivalRTPTime: UInt32? = nil) -> RTCPReceiverReportSnapshot? {
        lock.withLock {
            var tracker = trackersBySSRC[packet.ssrc] ?? RTCPReceiverReportTracker()
            tracker.observe(packet, arrivalRTPTime: arrivalRTPTime)
            let snapshot = tracker.snapshot(
                mediaSSRC: packet.ssrc,
                now: Date().timeIntervalSince1970
            )
            trackersBySSRC[packet.ssrc] = tracker
            return snapshot
        }
    }

    package func observe(_ packet: RTCPPacket, receivedAt: TimeInterval = Date().timeIntervalSince1970) {
        guard case let .senderReport(report) = packet else {
            return
        }

        lock.withLock {
            var tracker = trackersBySSRC[report.senderSSRC] ?? RTCPReceiverReportTracker()
            tracker.observe(report, receivedAt: receivedAt)
            trackersBySSRC[report.senderSSRC] = tracker
        }
    }

    package func receiverReportPacket(
        senderSSRC: UInt32,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> RTCPPacket? {
        lock.withLock {
            let mediaSSRCs = trackersBySSRC.keys.sorted().prefix(31)
            var reports: [RTCPReceptionReport] = []
            for mediaSSRC in mediaSSRCs {
                guard var tracker = trackersBySSRC[mediaSSRC],
                      let snapshot = tracker.report(mediaSSRC: mediaSSRC, now: now)
                else {
                    continue
                }
                reports.append(snapshot.report)
                trackersBySSRC[mediaSSRC] = tracker
            }

            guard !reports.isEmpty else {
                return nil
            }

            return .receiverReport(RTCPReceiverReport(senderSSRC: senderSSRC, reports: reports))
        }
    }

    package var snapshots: [RTCPReceiverReportSnapshot] {
        lock.withLock {
            let now = Date().timeIntervalSince1970
            return trackersBySSRC.keys.sorted().compactMap { mediaSSRC in
                trackersBySSRC[mediaSSRC]?.snapshot(mediaSSRC: mediaSSRC, now: now)
            }
        }
    }

    package func reset() {
        lock.withLock {
            trackersBySSRC.removeAll()
        }
    }
}
