import Foundation
import LiveKitNativeWebRTC

struct AdaptiveTrackSettingsPlan: Equatable, Sendable {
    var trackSIDs: [String]
    var disabled: Bool
    var quality: VideoQuality
    var width: UInt32
    var height: UInt32
    var fps: UInt32
    var priority: UInt32

    init(
        trackSIDs: [String],
        disabled: Bool,
        quality: VideoQuality,
        width: UInt32,
        height: UInt32,
        fps: UInt32,
        priority: UInt32 = 0
    ) {
        self.trackSIDs = trackSIDs
        self.disabled = disabled
        self.quality = quality
        self.width = width
        self.height = height
        self.fps = fps
        self.priority = priority
    }
}

struct AdaptiveTrackSettingsPlanner: Sendable {
    func plan(
        trackSIDs: [String],
        recommendation: AdaptiveVideoQualityRecommendation,
        priority: UInt32 = 0
    ) -> AdaptiveTrackSettingsPlan? {
        let trackSIDs = Array(trackSIDs.filter { !$0.isEmpty })
        guard !trackSIDs.isEmpty else {
            return nil
        }

        switch recommendation.level {
        case .suspended:
            return AdaptiveTrackSettingsPlan(
                trackSIDs: trackSIDs,
                disabled: true,
                quality: .off,
                width: 0,
                height: 0,
                fps: 0,
                priority: priority
            )
        case .low:
            return plan(trackSIDs: trackSIDs, quality: .low, recommendation: recommendation, priority: priority)
        case .medium:
            return plan(trackSIDs: trackSIDs, quality: .medium, recommendation: recommendation, priority: priority)
        case .high:
            return plan(trackSIDs: trackSIDs, quality: .high, recommendation: recommendation, priority: priority)
        }
    }

    private func plan(
        trackSIDs: [String],
        quality: VideoQuality,
        recommendation: AdaptiveVideoQualityRecommendation,
        priority: UInt32
    ) -> AdaptiveTrackSettingsPlan {
        AdaptiveTrackSettingsPlan(
            trackSIDs: trackSIDs,
            disabled: false,
            quality: quality,
            width: UInt32(max(0, recommendation.maxWidth)),
            height: UInt32(max(0, recommendation.maxHeight)),
            fps: UInt32(max(0, recommendation.maxFramesPerSecond)),
            priority: priority
        )
    }
}
