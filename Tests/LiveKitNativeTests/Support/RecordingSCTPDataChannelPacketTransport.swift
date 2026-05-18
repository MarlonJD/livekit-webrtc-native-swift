import Foundation
@testable import LiveKitNative
@testable import LiveKitNativeWebRTC

final class RecordingSCTPDataChannelPacketTransport: SCTPDataChannelPacketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableSentPackets: [SCTPDataChannelPacket] = []

    var sentPackets: [SCTPDataChannelPacket] {
        lock.withLock {
            mutableSentPackets
        }
    }

    func send(_ packet: SCTPDataChannelPacket) async throws {
        lock.withLock {
            mutableSentPackets.append(packet)
        }
    }
}
