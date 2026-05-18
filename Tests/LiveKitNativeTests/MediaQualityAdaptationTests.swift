import XCTest
@testable import LiveKitNativeWebRTC

final class MediaQualityAdaptationTests: XCTestCase {
    func testBandwidthEstimatorIncreasesOnLowLossAndDecreasesOnSevereLoss() {
        var estimator = RTCPBandwidthEstimator(policy: BandwidthEstimationPolicy(
            minimumBitrateBps: 100_000,
            maximumBitrateBps: 2_000_000,
            initialBitrateBps: 1_000_000,
            increaseFactor: 1.10,
            severeDecreaseFactor: 0.50
        ))

        let lowLoss = estimator.update(with: receptionReport(
            fractionLost: 0,
            cumulativePacketsLost: 0,
            highestSequenceNumber: 1_000
        ))
        XCTAssertEqual(lowLoss.estimatedBitrateBps, 1_100_000)
        XCTAssertEqual(lowLoss.recommendation.level, .medium)

        let severeLoss = estimator.update(with: receptionReport(
            fractionLost: 0,
            cumulativePacketsLost: 20,
            highestSequenceNumber: 1_100
        ))
        XCTAssertEqual(severeLoss.lossFraction, 0.20, accuracy: 0.001)
        XCTAssertEqual(severeLoss.estimatedBitrateBps, 550_000)
        XCTAssertEqual(severeLoss.recommendation.level, .low)
    }

    func testBandwidthEstimatorUsesReceiverReportFractionForFirstSampleAndClamps() {
        var estimator = RTCPBandwidthEstimator(policy: BandwidthEstimationPolicy(
            minimumBitrateBps: 300_000,
            maximumBitrateBps: 600_000,
            initialBitrateBps: 600_000,
            severeDecreaseFactor: 0.10
        ))

        let estimate = estimator.update(with: receptionReport(
            fractionLost: 64,
            cumulativePacketsLost: 0,
            highestSequenceNumber: 100
        ))

        XCTAssertEqual(estimate.lossFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(estimate.estimatedBitrateBps, 300_000)
        XCTAssertEqual(estimate.recommendation.level, .low)
    }

    func testAdaptiveVideoQualityRecommendationsMapBitrateTiers() {
        let policy = BandwidthEstimationPolicy()

        XCTAssertEqual(policy.recommendation(for: 250_000).level, .suspended)
        XCTAssertEqual(policy.recommendation(for: 500_000).maxHeight, 360)
        XCTAssertEqual(policy.recommendation(for: 1_000_000).maxHeight, 720)
        XCTAssertEqual(policy.recommendation(for: 2_000_000).maxHeight, 1_080)
    }

    func testFrameBackpressureDropsOverflowAndAllowsBoundedKeyFrameOverfill() {
        let controller = VideoFrameBackpressureController(policy: MediaFrameBackpressurePolicy(
            maxQueuedFrames: 2,
            maxFrameAgeMilliseconds: 100,
            keyFrameQueueOverfill: 1
        ))

        XCTAssertEqual(controller.beginFrame(), .send)
        XCTAssertEqual(controller.beginFrame(), .send)
        XCTAssertEqual(controller.beginFrame(), .drop(.queueFull))
        XCTAssertEqual(controller.beginFrame(isKeyFrame: true), .send)
        XCTAssertEqual(controller.beginFrame(isKeyFrame: true), .drop(.queueSaturated))

        var snapshot = controller.snapshot
        XCTAssertEqual(snapshot.queuedFrames, 3)
        XCTAssertEqual(snapshot.acceptedFrameCount, 3)
        XCTAssertEqual(snapshot.droppedFrameCount, 2)
        XCTAssertEqual(snapshot.droppedFramesByReason[.queueFull], 1)
        XCTAssertEqual(snapshot.droppedFramesByReason[.queueSaturated], 1)

        controller.endFrame()
        controller.endFrame()
        controller.endFrame()

        XCTAssertEqual(controller.beginFrame(frameAgeMilliseconds: 101), .drop(.stale))
        snapshot = controller.snapshot
        XCTAssertEqual(snapshot.queuedFrames, 0)
        XCTAssertEqual(snapshot.droppedFramesByReason[.stale], 1)
    }

    private func receptionReport(
        fractionLost: UInt8,
        cumulativePacketsLost: Int32,
        highestSequenceNumber: UInt32
    ) -> RTCPReceptionReport {
        RTCPReceptionReport(
            ssrc: 0x0102_0304,
            fractionLost: fractionLost,
            cumulativePacketsLost: cumulativePacketsLost,
            highestSequenceNumber: highestSequenceNumber,
            jitter: 0,
            lastSenderReport: 0,
            delaySinceLastSenderReport: 0
        )
    }
}
