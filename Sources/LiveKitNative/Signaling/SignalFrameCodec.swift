import Foundation
import SwiftProtobuf

public struct SignalFrameCodec: Sendable {
    public init() {}

    public func encode<Message: SwiftProtobuf.Message>(_ message: Message) throws -> Data {
        try message.serializedData()
    }

    public func decode<Message: SwiftProtobuf.Message>(_ messageType: Message.Type, from data: Data) throws -> Message {
        try Message(serializedBytes: data)
    }
}
