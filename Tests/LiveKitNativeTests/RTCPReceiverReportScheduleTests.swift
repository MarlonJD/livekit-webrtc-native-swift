import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class RTCPReceiverReportScheduleTests: XCTestCase {
    func testScheduleWaitsForIntervalAndRecordsAttempts() {
        let policy = RTCPReceiverReportSchedulePolicy(intervalSeconds: 5)
        var session = RTCPReceiverReportScheduleSession(startedAt: 100)

        XCTAssertNil(session.dueAction(at: 104.999, policy: policy))

        let firstAction = session.dueAction(at: 105, policy: policy)
        XCTAssertEqual(firstAction?.deadline, 105)
        XCTAssertEqual(firstAction?.now, 105)

        session.recordAttempt(at: 105)
        XCTAssertEqual(session.nextReportDeadline(policy: policy), 110)
        XCTAssertNil(session.dueAction(at: 109.999, policy: policy))
        XCTAssertEqual(session.dueAction(at: 110, policy: policy)?.deadline, 110)
    }

    func testDisabledPolicyDoesNotScheduleReports() {
        let policy = RTCPReceiverReportSchedulePolicy(intervalSeconds: 0.001, isEnabled: false)
        let session = RTCPReceiverReportScheduleSession(startedAt: 100)

        XCTAssertNil(session.dueAction(at: 1_000, policy: policy))
    }
}
