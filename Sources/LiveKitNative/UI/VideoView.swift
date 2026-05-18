#if canImport(UIKit)
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

@MainActor
public final class VideoView: UIView, SubscriberVideoFrameRenderer {
    public override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    public var track: VideoTrack?

    public var videoGravity: AVLayerVideoGravity {
        get {
            displayLayer.videoGravity
        }
        set {
            displayLayer.videoGravity = newValue
        }
    }

    public private(set) var renderedFrameCount = 0
    public private(set) var lastRenderedFrameSize: CGSize = .zero
    public private(set) var lastRenderError: (any Error)?

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureDisplayLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDisplayLayer()
    }

    public func flush() {
        displayLayer.flush()
        renderedFrameCount = 0
        lastRenderedFrameSize = .zero
        lastRenderError = nil
    }

    nonisolated public func render(_ frame: SubscriberVideoFrame) {
        Task { @MainActor [weak self] in
            self?.renderOnMain(frame)
        }
    }

    private func configureDisplayLayer() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    private func renderOnMain(_ frame: SubscriberVideoFrame) {
        do {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }

            let sampleBuffer = try VideoViewSampleBufferFactory.sampleBuffer(for: frame)
            displayLayer.enqueue(sampleBuffer)
            renderedFrameCount += 1
            lastRenderedFrameSize = CGSize(width: frame.width, height: frame.height)
            lastRenderError = nil
        } catch {
            lastRenderError = error
        }
    }
}
#elseif canImport(AppKit)
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import AppKit

@MainActor
public final class VideoView: NSView, SubscriberVideoFrameRenderer {
    public var track: VideoTrack? {
        didSet {
            needsDisplay = true
        }
    }

    public var videoGravity: AVLayerVideoGravity {
        get {
            displayLayer.videoGravity
        }
        set {
            displayLayer.videoGravity = newValue
        }
    }

    public private(set) var renderedFrameCount = 0
    public private(set) var lastRenderedFrameSize: CGSize = .zero
    public private(set) var lastRenderError: (any Error)?

    private let displayLayer = AVSampleBufferDisplayLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureDisplayLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDisplayLayer()
    }

    public override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    public func flush() {
        displayLayer.flush()
        renderedFrameCount = 0
        lastRenderedFrameSize = .zero
        lastRenderError = nil
    }

    nonisolated public func render(_ frame: SubscriberVideoFrame) {
        Task { @MainActor [weak self] in
            self?.renderOnMain(frame)
        }
    }

    private func configureDisplayLayer() {
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
    }

    private func renderOnMain(_ frame: SubscriberVideoFrame) {
        do {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }

            let sampleBuffer = try VideoViewSampleBufferFactory.sampleBuffer(for: frame)
            displayLayer.enqueue(sampleBuffer)
            renderedFrameCount += 1
            lastRenderedFrameSize = CGSize(width: frame.width, height: frame.height)
            lastRenderError = nil
        } catch {
            lastRenderError = error
        }
    }
}
#endif

#if canImport(UIKit) || canImport(AppKit)
public enum VideoViewRenderError: Error, Equatable, Sendable {
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
}

private enum VideoViewSampleBufferFactory {
    static func sampleBuffer(for frame: SubscriberVideoFrame) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw VideoViewRenderError.formatDescriptionCreationFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: frame.duration,
            presentationTimeStamp: frame.presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw VideoViewRenderError.sampleBufferCreationFailed(sampleStatus)
        }

        markForImmediateDisplay(sampleBuffer)
        return sampleBuffer
    }

    private static func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else {
            return
        }

        let attachment = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
#endif
