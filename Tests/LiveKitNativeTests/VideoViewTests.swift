#if canImport(UIKit) || canImport(AppKit)
import CoreMedia
import CoreVideo
import XCTest
@testable import LiveKitNative

@MainActor
final class VideoViewTests: XCTestCase {
    func testVideoViewRendersSubscriberFrame() async throws {
        let view = VideoView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let frame = SubscriberVideoFrame(
            timestamp: 90_000,
            presentationTimeStamp: CMTime(value: 1, timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            pixelBuffer: try Self.makeNV12PixelBuffer(width: 16, height: 16)
        )

        view.render(frame)

        for _ in 0..<100 where view.renderedFrameCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(view.renderedFrameCount, 1)
        XCTAssertEqual(view.lastRenderedFrameSize.width, 16)
        XCTAssertEqual(view.lastRenderedFrameSize.height, 16)
        XCTAssertNil(view.lastRenderError)

        view.flush()

        XCTAssertEqual(view.renderedFrameCount, 0)
        XCTAssertEqual(view.lastRenderedFrameSize, .zero)
        XCTAssertNil(view.lastRenderError)
    }

    private static func makeNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw VideoViewTestError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                continue
            }

            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            memset(baseAddress, plane == 0 ? 0x10 : 0x80, height * bytesPerRow)
        }

        return pixelBuffer
    }
}

private enum VideoViewTestError: Error {
    case pixelBufferCreationFailed(CVReturn)
}
#endif
