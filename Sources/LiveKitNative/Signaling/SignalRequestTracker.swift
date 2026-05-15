import Foundation
import LiveKitNativeProtocol

actor SignalRequestTracker {
    private var nextRequestID: UInt32 = 1
    private var responses: [UInt32: Livekit_RequestResponse] = [:]

    func nextID() -> UInt32 {
        let requestID = nextRequestID
        nextRequestID &+= 1
        if nextRequestID == 0 {
            nextRequestID = 1
        }
        return requestID
    }

    func fulfill(_ response: Livekit_RequestResponse) {
        responses[response.requestID] = response
    }

    func waitForResponse(
        requestID: UInt32,
        action: String,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws -> Livekit_RequestResponse {
        let pollInterval: UInt64 = 10_000_000
        var waited: UInt64 = 0

        while waited < timeoutNanoseconds {
            if let response = responses.removeValue(forKey: requestID) {
                return response
            }

            try await Task.sleep(nanoseconds: pollInterval)
            waited += pollInterval
        }

        responses.removeValue(forKey: requestID)
        throw LiveKitNativeError.requestTimedOut(action: action)
    }

    func clear() {
        responses.removeAll()
    }
}
