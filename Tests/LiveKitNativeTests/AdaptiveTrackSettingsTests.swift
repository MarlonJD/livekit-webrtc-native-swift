import XCTest
@testable import LiveKitNative
@testable import LiveKitNativeWebRTC

final class AdaptiveTrackSettingsTests: XCTestCase {
    func testPlannerMapsRecommendationsToTrackSettingsPlans() {
        let planner = AdaptiveTrackSettingsPlanner()

        XCTAssertEqual(
            planner.plan(
                trackSIDs: ["TR_camera"],
                recommendation: AdaptiveVideoQualityRecommendation(
                    level: .low,
                    targetBitrateBps: 500_000,
                    maxWidth: 640,
                    maxHeight: 360,
                    maxFramesPerSecond: 15
                ),
                priority: 2
            ),
            AdaptiveTrackSettingsPlan(
                trackSIDs: ["TR_camera"],
                disabled: false,
                quality: .low,
                width: 640,
                height: 360,
                fps: 15,
                priority: 2
            )
        )

        XCTAssertEqual(
            planner.plan(
                trackSIDs: ["TR_camera"],
                recommendation: AdaptiveVideoQualityRecommendation(
                    level: .high,
                    targetBitrateBps: 2_000_000,
                    maxWidth: 1_920,
                    maxHeight: 1_080,
                    maxFramesPerSecond: 30
                )
            )?.quality,
            .high
        )
    }

    func testPlannerSuspendsEmptyOrDisabledTracks() {
        let planner = AdaptiveTrackSettingsPlanner()

        XCTAssertNil(planner.plan(
            trackSIDs: [],
            recommendation: AdaptiveVideoQualityRecommendation(
                level: .low,
                targetBitrateBps: 500_000,
                maxWidth: 640,
                maxHeight: 360,
                maxFramesPerSecond: 15
            )
        ))

        XCTAssertEqual(
            planner.plan(
                trackSIDs: ["", "TR_camera"],
                recommendation: AdaptiveVideoQualityRecommendation(
                    level: .suspended,
                    targetBitrateBps: 250_000,
                    maxWidth: 0,
                    maxHeight: 0,
                    maxFramesPerSecond: 0
                )
            ),
            AdaptiveTrackSettingsPlan(
                trackSIDs: ["TR_camera"],
                disabled: true,
                quality: .off,
                width: 0,
                height: 0,
                fps: 0
            )
        )
    }
}
