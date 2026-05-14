#if canImport(UIKit)
import UIKit

@MainActor
public final class VideoView: UIView {
    public var track: VideoTrack?
}
#elseif canImport(AppKit)
import AppKit

@MainActor
public final class VideoView: NSView {
    public var track: VideoTrack? {
        didSet {
            needsDisplay = true
        }
    }
}
#endif
