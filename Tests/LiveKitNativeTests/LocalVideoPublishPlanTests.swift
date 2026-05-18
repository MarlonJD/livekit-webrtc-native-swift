import XCTest
@testable import LiveKitNative
@testable import LiveKitNativeWebRTC

final class LocalVideoPublishPlanTests: XCTestCase {
    func testCameraTrackCarriesNativeCameraConfiguration() throws {
        let track = try LocalVideoTrack.createCameraTrack(
            options: CameraCaptureOptions(position: .back, width: 1_920, height: 1_080, framesPerSecond: 60)
        )

        XCTAssertEqual(track.name, "camera")
        XCTAssertEqual(track.source, .camera)
        XCTAssertEqual(track.cameraCaptureOptions?.position, .back)
        XCTAssertEqual(track.cameraCaptureOptions?.width, 1_920)
        XCTAssertEqual(track.nativeCameraSource?.configuration.position, .back)
        XCTAssertEqual(track.nativeCameraSource?.configuration.width, 1_920)
        XCTAssertEqual(track.nativeCameraSource?.configuration.height, 1_080)
        XCTAssertEqual(track.nativeCameraSource?.configuration.framesPerSecond, 60)
    }

    func testLocalVideoPublishPlanBuildsH264AddTrackRequest() throws {
        let track = try LocalVideoTrack.createCameraTrack(
            options: CameraCaptureOptions(width: 1_280, height: 720, framesPerSecond: 30)
        )
        let plan = LocalVideoPublishPlan(
            track: track,
            options: TrackPublishOptions(name: "main-camera", source: .camera, simulcast: true),
            ssrc: 1234,
            payloadType: 102
        )
        let request = plan.addTrackRequest

        XCTAssertEqual(request.cid, track.id)
        XCTAssertEqual(request.name, "main-camera")
        XCTAssertEqual(request.type, .video)
        XCTAssertEqual(request.width, 1_280)
        XCTAssertEqual(request.height, 720)
        XCTAssertEqual(request.source, .camera)
        XCTAssertEqual(request.layers.count, 1)
        XCTAssertEqual(request.layers[0].ssrc, 1234)
        XCTAssertEqual(request.layers[0].width, 1_280)
        XCTAssertEqual(request.layers[0].height, 720)
        XCTAssertEqual(request.layers[0].quality, .high)
        XCTAssertEqual(request.simulcastCodecs.count, 1)
        XCTAssertEqual(request.simulcastCodecs[0].codec, "video/H264")
        XCTAssertEqual(request.simulcastCodecs[0].videoLayerMode, .oneSpatialLayerPerStream)
        XCTAssertEqual(plan.codec, .h264)
        XCTAssertEqual(plan.encoderSettings.width, 1_280)
        XCTAssertEqual(plan.encoderSettings.height, 720)
        XCTAssertEqual(plan.encoderSettings.framesPerSecond, 30)
    }

    func testLocalVideoPublishPlanCanDisableSimulcastCodecAdvertisement() throws {
        let track = try LocalVideoTrack.createCameraTrack(
            options: CameraCaptureOptions(width: 640, height: 360, framesPerSecond: 15)
        )
        let plan = LocalVideoPublishPlan(
            track: track,
            options: TrackPublishOptions(simulcast: false),
            ssrc: 5678
        )
        let request = plan.addTrackRequest

        XCTAssertEqual(request.layers.count, 1)
        XCTAssertEqual(request.layers[0].quality, .high)
        XCTAssertEqual(request.layers[0].width, 640)
        XCTAssertEqual(request.layers[0].height, 360)
        XCTAssertEqual(request.simulcastCodecs, [])
    }
}
