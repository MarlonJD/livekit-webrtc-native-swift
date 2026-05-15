import Foundation
import LiveKitNativeProtocol

actor SignalRequestTracker {
    private var nextRequestID: UInt32 = 1
    private var responses: [UInt32: Livekit_RequestResponse] = [:]
    private var trackPublishedResponses: [String: Livekit_TrackPublishedResponse] = [:]

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

    func fulfill(_ response: Livekit_TrackPublishedResponse) {
        trackPublishedResponses[response.cid] = response
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

    func waitForTrackPublished(
        cid: String,
        action: String,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws -> Livekit_TrackPublishedResponse {
        let pollInterval: UInt64 = 10_000_000
        var waited: UInt64 = 0

        while waited < timeoutNanoseconds {
            if let response = trackPublishedResponses.removeValue(forKey: cid) {
                return response
            }

            try await Task.sleep(nanoseconds: pollInterval)
            waited += pollInterval
        }

        trackPublishedResponses.removeValue(forKey: cid)
        throw LiveKitNativeError.requestTimedOut(action: action)
    }

    func clear() {
        responses.removeAll()
        trackPublishedResponses.removeAll()
    }
}
