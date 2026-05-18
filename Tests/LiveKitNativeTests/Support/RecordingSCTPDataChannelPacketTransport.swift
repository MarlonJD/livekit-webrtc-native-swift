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

final class ScriptedSCTPDataChannelPacketTransceiver: SCTPDataChannelPacketTransceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableSentPackets: [SCTPDataChannelPacket] = []
    private var mutableIncomingPackets: [SCTPDataChannelPacket] = []
    private var mutableReceiveContinuations: [UUID: CheckedContinuation<SCTPDataChannelPacket, any Error>] = [:]

    var sentPackets: [SCTPDataChannelPacket] {
        lock.withLock {
            mutableSentPackets
        }
    }

    func waitForSentPacketCount(_ expectedCount: Int) async -> [SCTPDataChannelPacket] {
        for _ in 0..<100 {
            let packets = sentPackets
            if packets.count >= expectedCount {
                return packets
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return sentPackets
    }

    func enqueueIncomingPacket(_ packet: SCTPDataChannelPacket) {
        let continuation: CheckedContinuation<SCTPDataChannelPacket, any Error>? = lock.withLock {
            if let id = mutableReceiveContinuations.keys.first,
               let continuation = mutableReceiveContinuations.removeValue(forKey: id) {
                return continuation
            }

            mutableIncomingPackets.append(packet)
            return nil
        }

        continuation?.resume(returning: packet)
    }

    func send(_ packet: SCTPDataChannelPacket) async throws {
        lock.withLock {
            mutableSentPackets.append(packet)
        }
    }

    func receive() async throws -> SCTPDataChannelPacket {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCTPDataChannelPacket, any Error>) in
                let immediateResult: Result<SCTPDataChannelPacket, any Error>? = lock.withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }

                    guard !mutableIncomingPackets.isEmpty else {
                        mutableReceiveContinuations[id] = continuation
                        return nil
                    }

                    return .success(mutableIncomingPackets.removeFirst())
                }

                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                mutableReceiveContinuations.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
