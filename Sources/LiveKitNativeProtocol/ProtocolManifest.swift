import Foundation
import SwiftProtobuf

public enum LiveKitProtocolManifest {
    public static let protocolVersion = 9
    public static let sourceRepository = URL(string: "https://github.com/livekit/protocol")!
    public static let pinnedCommit = "765a80e4298e376593859c3f11cf748c725f68f9"
    public static let generatedSourceStatus = "Client signaling protobuf Swift sources are vendored from the pinned LiveKit protocol revision."
}

public typealias SignalRequestFrame = Livekit_SignalRequest
public typealias SignalResponseFrame = Livekit_SignalResponse
