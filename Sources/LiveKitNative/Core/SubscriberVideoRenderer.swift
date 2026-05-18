import CoreMedia
import CoreVideo
import Foundation
import LiveKitNativeWebRTC

public struct SubscriberVideoFrame: @unchecked Sendable {
    public let timestamp: UInt32
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
    public let pixelBuffer: CVPixelBuffer

    public var width: Int {
        CVPixelBufferGetWidth(pixelBuffer)
    }

    public var height: Int {
        CVPixelBufferGetHeight(pixelBuffer)
    }

    public init(
        timestamp: UInt32,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        pixelBuffer: CVPixelBuffer
    ) {
        self.timestamp = timestamp
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.pixelBuffer = pixelBuffer
    }
}

public protocol SubscriberVideoFrameRenderer: AnyObject, Sendable {
    func render(_ frame: SubscriberVideoFrame)
}

final class SubscriberVideoFrameRendererBridge: H264DecodedFrameRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private weak var renderer: (any SubscriberVideoFrameRenderer)?

    func setRenderer(_ renderer: (any SubscriberVideoFrameRenderer)?) {
        lock.withLock {
            self.renderer = renderer
        }
    }

    func render(_ frame: H264DecodedFrame) {
        let renderer: (any SubscriberVideoFrameRenderer)? = lock.withLock {
            self.renderer
        }
        renderer?.render(SubscriberVideoFrame(decodedFrame: frame))
    }
}

private extension SubscriberVideoFrame {
    init(decodedFrame: H264DecodedFrame) {
        self.init(
            timestamp: decodedFrame.timestamp,
            presentationTimeStamp: decodedFrame.presentationTimeStamp,
            duration: decodedFrame.duration,
            pixelBuffer: decodedFrame.pixelBuffer
        )
    }
}
