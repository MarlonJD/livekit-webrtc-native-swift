import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class ICEConsentFreshnessTests: XCTestCase {
    func testInitialSchedulingUsesPolicyIntervalAndTimeout() {
        let policy = ICEConsentFreshnessPolicy(intervalSeconds: 15, timeoutSeconds: 30)
        let session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 100
        )

        XCTAssertEqual(session.nextCheckDeadline(policy: policy), 115)
        XCTAssertEqual(session.timeoutDeadline(policy: policy), 130)
        XCTAssertFalse(session.isExpired(at: 129.999, policy: policy))

        let actions = session.dueActions(at: 115, policy: policy)

        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.dueAt, 115)
        XCTAssertEqual(actions.first?.nextCheckDeadline, 115)
        XCTAssertEqual(actions.first?.timeoutDeadline, 130)
        XCTAssertEqual(actions.first?.isExpired, false)
    }

    func testSuccessAdvancesDeadlineAndResetsFailures() {
        let policy = ICEConsentFreshnessPolicy(
            intervalSeconds: 10,
            timeoutSeconds: 30,
            maxConsecutiveFailures: 2
        )
        var session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 50
        )

        session.recordFailure(at: 60)
        session.recordSuccess(at: 70)

        XCTAssertEqual(session.consecutiveFailures, 0)
        XCTAssertEqual(session.lastSuccessAt, 70)
        XCTAssertEqual(session.nextCheckDeadline(policy: policy), 80)
        XCTAssertEqual(session.timeoutDeadline(policy: policy), 100)
        XCTAssertEqual(session.dueActions(at: 79.999, policy: policy), [])
        XCTAssertEqual(session.dueActions(at: 80, policy: policy).first?.dueAt, 80)
    }

    func testFailureCountExpiresAtMaximumConsecutiveFailures() {
        let policy = ICEConsentFreshnessPolicy(
            intervalSeconds: 10,
            timeoutSeconds: 120,
            maxConsecutiveFailures: 2
        )
        var session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 10
        )

        session.recordFailure(at: 20)
        XCTAssertFalse(session.isExpired(at: 20, policy: policy))

        session.recordFailure(at: 30)

        XCTAssertTrue(session.isExpired(at: 30, policy: policy))
        let action = session.dueActions(at: 40, policy: policy).first
        XCTAssertEqual(action?.consecutiveFailures, 2)
        XCTAssertEqual(action?.isExpired, true)
    }

    func testTimeoutExpiryProducesExpiredDueActionAtTimeoutDeadline() {
        let policy = ICEConsentFreshnessPolicy(
            intervalSeconds: 100,
            timeoutSeconds: 30,
            maxConsecutiveFailures: 6
        )
        let session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 100
        )

        XCTAssertEqual(session.dueActions(at: 129.999, policy: policy), [])
        XCTAssertFalse(session.isExpired(at: 129.999, policy: policy))

        let action = session.dueActions(at: 130, policy: policy).first

        XCTAssertTrue(session.isExpired(at: 130, policy: policy))
        XCTAssertEqual(action?.dueAt, 130)
        XCTAssertEqual(action?.nextCheckDeadline, 200)
        XCTAssertEqual(action?.timeoutDeadline, 130)
        XCTAssertEqual(action?.isExpired, true)
    }

    func testNegativeJitterIsClampedToZero() {
        let clamped = ICEConsentFreshnessPolicy(
            intervalSeconds: 15,
            timeoutSeconds: 30,
            jitterSeconds: -5
        )
        let noJitter = ICEConsentFreshnessPolicy(
            intervalSeconds: 15,
            timeoutSeconds: 30
        )
        let session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 200
        )

        XCTAssertEqual(clamped.jitterSeconds, 0)
        XCTAssertEqual(session.nextCheckDeadline(policy: clamped), session.nextCheckDeadline(policy: noJitter))
    }

    func testPositiveJitterMovesCheckDeadlineEarlierDeterministically() {
        let policy = ICEConsentFreshnessPolicy(
            intervalSeconds: 15,
            timeoutSeconds: 30,
            jitterSeconds: 5
        )
        let session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 200
        )

        XCTAssertEqual(policy.effectiveJitterSeconds, 5)
        XCTAssertEqual(session.nextCheckDeadline(policy: policy), 210)
        XCTAssertEqual(session.dueActions(at: 209.999, policy: policy), [])
        XCTAssertEqual(session.dueActions(at: 210, policy: policy).first?.dueAt, 210)
    }

    func testNoActionBeforeDue() {
        let policy = ICEConsentFreshnessPolicy(intervalSeconds: 10, timeoutSeconds: 30)
        let session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 0
        )

        XCTAssertEqual(session.dueActions(at: 9.999, policy: policy), [])
        XCTAssertEqual(session.dueActions(at: 10, policy: policy).count, 1)
    }

    func testDisabledOrMissingSelectedPairProducesNoDueAction() {
        let policy = ICEConsentFreshnessPolicy(intervalSeconds: 10, timeoutSeconds: 30)
        let disabled = ICEConsentFreshnessPolicy(
            intervalSeconds: 10,
            timeoutSeconds: 30,
            isEnabled: false
        )
        let sessionWithoutPair = ICEConsentFreshnessSession(
            selectedPair: nil,
            startedAt: 0
        )
        let sessionWithPair = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 0
        )

        XCTAssertEqual(sessionWithoutPair.dueActions(at: 30, policy: policy), [])
        XCTAssertEqual(sessionWithPair.dueActions(at: 30, policy: disabled), [])
    }
}

private func candidatePair() -> ICECandidatePair {
    ICECandidatePair(
        local: ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 5_000,
            type: .host
        ),
        remote: ICECandidate(
            foundation: "remote",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .serverReflexive, localPreference: 100).value,
            address: "203.0.113.20",
            port: 6_000,
            type: .serverReflexive
        ),
        isControlling: true,
        state: .succeeded,
        nominated: true
    )
}
