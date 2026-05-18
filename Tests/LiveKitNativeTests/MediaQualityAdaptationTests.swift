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

    func testBandwidthEstimateStoreUpdatesFromReceiverAndSenderReportsBySSRC() {
        let store = RTCPBandwidthEstimateStore(policy: BandwidthEstimationPolicy(
            initialBitrateBps: 1_000_000,
            increaseFactor: 1.10,
            severeDecreaseFactor: 0.50
        ))

        let firstUpdates = store.update(with: .receiverReport(RTCPReceiverReport(
            senderSSRC: 0xAAAA,
            reports: [
                receptionReport(
                    ssrc: 0x2222,
                    fractionLost: 0,
                    cumulativePacketsLost: 0,
                    highestSequenceNumber: 100
                ),
                receptionReport(
                    ssrc: 0x1111,
                    fractionLost: 64,
                    cumulativePacketsLost: 0,
                    highestSequenceNumber: 200
                ),
            ]
        )))

        XCTAssertEqual(firstUpdates.map(\.ssrc), [0x2222, 0x1111])
        XCTAssertEqual(firstUpdates[0].estimate.estimatedBitrateBps, 1_100_000)
        XCTAssertEqual(firstUpdates[1].estimate.estimatedBitrateBps, 500_000)
        XCTAssertEqual(store.snapshots.map(\.ssrc), [0x1111, 0x2222])

        let senderReportUpdates = store.update(with: .senderReport(RTCPSenderReport(
            senderSSRC: 0xBBBB,
            ntpTimestamp: 0,
            rtpTimestamp: 0,
            packetCount: 0,
            octetCount: 0,
            reports: [
                receptionReport(
                    ssrc: 0x2222,
                    fractionLost: 0,
                    cumulativePacketsLost: 20,
                    highestSequenceNumber: 200
                ),
            ]
        )))

        XCTAssertEqual(senderReportUpdates.count, 1)
        let senderReportUpdate = senderReportUpdates[0]
        XCTAssertEqual(senderReportUpdate.ssrc, 0x2222)
        XCTAssertEqual(senderReportUpdate.estimate.lossFraction, 0.20, accuracy: 0.001)
        XCTAssertEqual(senderReportUpdate.estimate.estimatedBitrateBps, 550_000)

        store.reset()
        XCTAssertEqual(store.snapshots, [])
    }

    func testReceiverEstimatedMaximumBitratePlannerUsesLowestEstimateAcrossSSRCs() {
        let packet = RTCPReceiverEstimatedMaximumBitratePlanner().packet(
            senderSSRC: 0x0102_0304,
            snapshots: [
                MediaQualityEstimateSnapshot(
                    ssrc: 0x2222,
                    estimate: BandwidthEstimate(
                        estimatedBitrateBps: 1_500_000,
                        lossFraction: 0,
                        recommendation: BandwidthEstimationPolicy().recommendation(for: 1_500_000)
                    )
                ),
                MediaQualityEstimateSnapshot(
                    ssrc: 0x1111,
                    estimate: BandwidthEstimate(
                        estimatedBitrateBps: 750_000,
                        lossFraction: 0.10,
                        recommendation: BandwidthEstimationPolicy().recommendation(for: 750_000)
                    )
                ),
            ]
        )

        guard case let .receiverEstimatedMaximumBitrate(remb) = packet else {
            return XCTFail("Expected REMB packet.")
        }
        XCTAssertEqual(remb.senderSSRC, 0x0102_0304)
        XCTAssertEqual(remb.bitrateBps, 750_000)
        XCTAssertEqual(remb.ssrcs, [0x1111, 0x2222])
    }

    func testReceiverEstimatedMaximumBitratePlannerSkipsEmptySnapshots() {
        XCTAssertNil(RTCPReceiverEstimatedMaximumBitratePlanner().packet(
            senderSSRC: 0x0102_0304,
            snapshots: []
        ))
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
        ssrc: UInt32 = 0x0102_0304,
        fractionLost: UInt8,
        cumulativePacketsLost: Int32,
        highestSequenceNumber: UInt32
    ) -> RTCPReceptionReport {
        RTCPReceptionReport(
            ssrc: ssrc,
            fractionLost: fractionLost,
            cumulativePacketsLost: cumulativePacketsLost,
            highestSequenceNumber: highestSequenceNumber,
            jitter: 0,
            lastSenderReport: 0,
            delaySinceLastSenderReport: 0
        )
    }
}
