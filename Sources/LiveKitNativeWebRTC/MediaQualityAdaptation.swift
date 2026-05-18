import Foundation

package enum MediaQualityLevel: Int, Equatable, Comparable, Sendable {
    case suspended = 0
    case low = 1
    case medium = 2
    case high = 3

    package static func < (lhs: MediaQualityLevel, rhs: MediaQualityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct AdaptiveVideoQualityRecommendation: Equatable, Sendable {
    package var level: MediaQualityLevel
    package var targetBitrateBps: Int
    package var maxWidth: Int
    package var maxHeight: Int
    package var maxFramesPerSecond: Int

    package init(
        level: MediaQualityLevel,
        targetBitrateBps: Int,
        maxWidth: Int,
        maxHeight: Int,
        maxFramesPerSecond: Int
    ) {
        self.level = level
        self.targetBitrateBps = targetBitrateBps
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFramesPerSecond = maxFramesPerSecond
    }
}

package struct BandwidthEstimationPolicy: Equatable, Sendable {
    package var minimumBitrateBps: Int
    package var maximumBitrateBps: Int
    package var initialBitrateBps: Int
    package var lowLossThreshold: Double
    package var moderateLossThreshold: Double
    package var severeLossThreshold: Double
    package var increaseFactor: Double
    package var decreaseFactor: Double
    package var severeDecreaseFactor: Double

    package init(
        minimumBitrateBps: Int = 150_000,
        maximumBitrateBps: Int = 4_000_000,
        initialBitrateBps: Int = 1_500_000,
        lowLossThreshold: Double = 0.02,
        moderateLossThreshold: Double = 0.05,
        severeLossThreshold: Double = 0.10,
        increaseFactor: Double = 1.08,
        decreaseFactor: Double = 0.85,
        severeDecreaseFactor: Double = 0.65
    ) {
        self.minimumBitrateBps = max(1, minimumBitrateBps)
        self.maximumBitrateBps = max(self.minimumBitrateBps, maximumBitrateBps)
        self.initialBitrateBps = min(max(initialBitrateBps, self.minimumBitrateBps), self.maximumBitrateBps)
        self.lowLossThreshold = max(0, lowLossThreshold)
        self.moderateLossThreshold = max(self.lowLossThreshold, moderateLossThreshold)
        self.severeLossThreshold = max(self.moderateLossThreshold, severeLossThreshold)
        self.increaseFactor = max(1, increaseFactor)
        self.decreaseFactor = min(max(0, decreaseFactor), 1)
        self.severeDecreaseFactor = min(max(0, severeDecreaseFactor), self.decreaseFactor)
    }

    package func qualityLevel(for bitrateBps: Int) -> MediaQualityLevel {
        switch bitrateBps {
        case ..<300_000:
            .suspended
        case ..<900_000:
            .low
        case ..<1_800_000:
            .medium
        default:
            .high
        }
    }

    package func recommendation(for bitrateBps: Int) -> AdaptiveVideoQualityRecommendation {
        let clampedBitrate = clamp(bitrateBps)
        switch qualityLevel(for: clampedBitrate) {
        case .suspended:
            return AdaptiveVideoQualityRecommendation(
                level: .suspended,
                targetBitrateBps: clampedBitrate,
                maxWidth: 0,
                maxHeight: 0,
                maxFramesPerSecond: 0
            )
        case .low:
            return AdaptiveVideoQualityRecommendation(
                level: .low,
                targetBitrateBps: clampedBitrate,
                maxWidth: 640,
                maxHeight: 360,
                maxFramesPerSecond: 15
            )
        case .medium:
            return AdaptiveVideoQualityRecommendation(
                level: .medium,
                targetBitrateBps: clampedBitrate,
                maxWidth: 1_280,
                maxHeight: 720,
                maxFramesPerSecond: 24
            )
        case .high:
            return AdaptiveVideoQualityRecommendation(
                level: .high,
                targetBitrateBps: clampedBitrate,
                maxWidth: 1_920,
                maxHeight: 1_080,
                maxFramesPerSecond: 30
            )
        }
    }

    package func clamp(_ bitrateBps: Int) -> Int {
        min(max(bitrateBps, minimumBitrateBps), maximumBitrateBps)
    }
}

package struct BandwidthEstimate: Equatable, Sendable {
    package var estimatedBitrateBps: Int
    package var lossFraction: Double
    package var recommendation: AdaptiveVideoQualityRecommendation

    package init(
        estimatedBitrateBps: Int,
        lossFraction: Double,
        recommendation: AdaptiveVideoQualityRecommendation
    ) {
        self.estimatedBitrateBps = estimatedBitrateBps
        self.lossFraction = lossFraction
        self.recommendation = recommendation
    }
}

package struct MediaQualityEstimateSnapshot: Equatable, Sendable {
    package var ssrc: UInt32
    package var estimate: BandwidthEstimate

    package init(ssrc: UInt32, estimate: BandwidthEstimate) {
        self.ssrc = ssrc
        self.estimate = estimate
    }
}

package struct RTCPReceiverEstimatedMaximumBitratePlanner: Equatable, Sendable {
    package var minimumAdvertisedBitrateBps: Int

    package init(minimumAdvertisedBitrateBps: Int = 1) {
        self.minimumAdvertisedBitrateBps = max(1, minimumAdvertisedBitrateBps)
    }

    package func packet(
        senderSSRC: UInt32,
        mediaSSRC: UInt32 = 0,
        snapshots: [MediaQualityEstimateSnapshot]
    ) -> RTCPPacket? {
        let orderedSnapshots = snapshots.sorted { $0.ssrc < $1.ssrc }
        guard !orderedSnapshots.isEmpty else {
            return nil
        }

        let bitrateBps = orderedSnapshots
            .map { max(minimumAdvertisedBitrateBps, $0.estimate.estimatedBitrateBps) }
            .min() ?? minimumAdvertisedBitrateBps

        return .receiverEstimatedMaximumBitrate(
            RTCPReceiverEstimatedMaximumBitrate(
                senderSSRC: senderSSRC,
                mediaSSRC: mediaSSRC,
                bitrateBps: UInt64(bitrateBps),
                ssrcs: orderedSnapshots.map(\.ssrc)
            )
        )
    }
}

package struct RTCPBandwidthEstimator: Sendable {
    package var policy: BandwidthEstimationPolicy
    private var estimatedBitrateBps: Int
    private var previousReport: RTCPReceptionReport?

    package init(policy: BandwidthEstimationPolicy = BandwidthEstimationPolicy()) {
        self.policy = policy
        self.estimatedBitrateBps = policy.initialBitrateBps
    }

    package var currentEstimate: BandwidthEstimate {
        BandwidthEstimate(
            estimatedBitrateBps: estimatedBitrateBps,
            lossFraction: 0,
            recommendation: policy.recommendation(for: estimatedBitrateBps)
        )
    }

    package mutating func update(with report: RTCPReceptionReport) -> BandwidthEstimate {
        let lossFraction = Self.lossFraction(current: report, previous: previousReport)
        previousReport = report

        let factor: Double
        if lossFraction >= policy.severeLossThreshold {
            factor = policy.severeDecreaseFactor
        } else if lossFraction >= policy.moderateLossThreshold {
            factor = policy.decreaseFactor
        } else if lossFraction <= policy.lowLossThreshold {
            factor = policy.increaseFactor
        } else {
            factor = 1
        }

        estimatedBitrateBps = policy.clamp(Int(Double(estimatedBitrateBps) * factor))
        return BandwidthEstimate(
            estimatedBitrateBps: estimatedBitrateBps,
            lossFraction: lossFraction,
            recommendation: policy.recommendation(for: estimatedBitrateBps)
        )
    }

    private static func lossFraction(
        current: RTCPReceptionReport,
        previous: RTCPReceptionReport?
    ) -> Double {
        guard let previous,
              current.highestSequenceNumber > previous.highestSequenceNumber
        else {
            return Double(current.fractionLost) / 256.0
        }

        let expectedDelta = max(1, Int(current.highestSequenceNumber - previous.highestSequenceNumber))
        let lostDelta = max(0, Int(current.cumulativePacketsLost - previous.cumulativePacketsLost))
        return min(1, Double(lostDelta) / Double(expectedDelta))
    }
}

package final class RTCPBandwidthEstimateStore: @unchecked Sendable {
    private let policy: BandwidthEstimationPolicy
    private let lock = NSLock()
    private var estimatorsBySSRC: [UInt32: RTCPBandwidthEstimator] = [:]
    private var estimatesBySSRC: [UInt32: BandwidthEstimate] = [:]

    package init(policy: BandwidthEstimationPolicy = BandwidthEstimationPolicy()) {
        self.policy = policy
    }

    package var snapshots: [MediaQualityEstimateSnapshot] {
        lock.withLock {
            estimatesBySSRC
                .map { MediaQualityEstimateSnapshot(ssrc: $0.key, estimate: $0.value) }
                .sorted { $0.ssrc < $1.ssrc }
        }
    }

    @discardableResult
    package func update(with packet: RTCPPacket) -> [MediaQualityEstimateSnapshot] {
        let reports: [RTCPReceptionReport]
        switch packet {
        case let .receiverReport(report):
            reports = report.reports
        case let .senderReport(report):
            reports = report.reports
        case .pictureLossIndication,
             .transportLayerNACK,
             .receiverEstimatedMaximumBitrate,
             .applicationLayerFeedback:
            reports = []
        }

        guard !reports.isEmpty else {
            return []
        }

        return lock.withLock {
            reports.map { report in
                var estimator = estimatorsBySSRC[report.ssrc] ?? RTCPBandwidthEstimator(policy: policy)
                let estimate = estimator.update(with: report)
                estimatorsBySSRC[report.ssrc] = estimator
                estimatesBySSRC[report.ssrc] = estimate
                return MediaQualityEstimateSnapshot(ssrc: report.ssrc, estimate: estimate)
            }
        }
    }

    package func reset() {
        lock.withLock {
            estimatorsBySSRC.removeAll()
            estimatesBySSRC.removeAll()
        }
    }
}

package enum MediaFrameDropReason: Equatable, Hashable, Sendable {
    case stale
    case queueFull
    case queueSaturated
}

package enum MediaFrameBackpressureDecision: Equatable, Sendable {
    case send
    case drop(MediaFrameDropReason)

    package var shouldSend: Bool {
        self == .send
    }
}

package struct MediaFrameBackpressurePolicy: Equatable, Sendable {
    package var maxQueuedFrames: Int
    package var maxFrameAgeMilliseconds: Int
    package var keyFrameQueueOverfill: Int

    package init(
        maxQueuedFrames: Int = 3,
        maxFrameAgeMilliseconds: Int = 250,
        keyFrameQueueOverfill: Int = 1
    ) {
        self.maxQueuedFrames = max(1, maxQueuedFrames)
        self.maxFrameAgeMilliseconds = max(0, maxFrameAgeMilliseconds)
        self.keyFrameQueueOverfill = max(0, keyFrameQueueOverfill)
    }

    package func decision(
        queuedFrames: Int,
        frameAgeMilliseconds: Int = 0,
        isKeyFrame: Bool = false
    ) -> MediaFrameBackpressureDecision {
        if frameAgeMilliseconds > maxFrameAgeMilliseconds {
            return .drop(.stale)
        }

        if queuedFrames < maxQueuedFrames {
            return .send
        }

        if isKeyFrame, queuedFrames < maxQueuedFrames + keyFrameQueueOverfill {
            return .send
        }

        return .drop(isKeyFrame ? .queueSaturated : .queueFull)
    }
}

package struct MediaFrameBackpressureSnapshot: Equatable, Sendable {
    package var queuedFrames: Int
    package var acceptedFrameCount: Int
    package var droppedFrameCount: Int
    package var droppedFramesByReason: [MediaFrameDropReason: Int]
}

package final class VideoFrameBackpressureController: @unchecked Sendable {
    package let policy: MediaFrameBackpressurePolicy

    private let lock = NSLock()
    private var mutableQueuedFrames = 0
    private var mutableAcceptedFrameCount = 0
    private var mutableDroppedFrameCount = 0
    private var mutableDroppedFramesByReason: [MediaFrameDropReason: Int] = [:]

    package init(policy: MediaFrameBackpressurePolicy = MediaFrameBackpressurePolicy()) {
        self.policy = policy
    }

    package var snapshot: MediaFrameBackpressureSnapshot {
        lock.withLock {
            MediaFrameBackpressureSnapshot(
                queuedFrames: mutableQueuedFrames,
                acceptedFrameCount: mutableAcceptedFrameCount,
                droppedFrameCount: mutableDroppedFrameCount,
                droppedFramesByReason: mutableDroppedFramesByReason
            )
        }
    }

    package func beginFrame(
        isKeyFrame: Bool = false,
        frameAgeMilliseconds: Int = 0
    ) -> MediaFrameBackpressureDecision {
        lock.withLock {
            let decision = policy.decision(
                queuedFrames: mutableQueuedFrames,
                frameAgeMilliseconds: frameAgeMilliseconds,
                isKeyFrame: isKeyFrame
            )
            switch decision {
            case .send:
                mutableQueuedFrames += 1
                mutableAcceptedFrameCount += 1
            case let .drop(reason):
                mutableDroppedFrameCount += 1
                mutableDroppedFramesByReason[reason, default: 0] += 1
            }
            return decision
        }
    }

    package func endFrame() {
        lock.withLock {
            mutableQueuedFrames = max(0, mutableQueuedFrames - 1)
        }
    }
}
