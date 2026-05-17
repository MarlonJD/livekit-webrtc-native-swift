import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class ICEConsentFreshnessExecutorTests: XCTestCase {
    func testNoActionBeforeDueDoesNotCallChecker() {
        var session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 100
        )
        let recorder = ICEConsentFreshnessCheckRecorder(result: true)
        let executor = makeExecutor(recorder: recorder)

        let result = executor.execute(session: &session, at: 109.999)

        XCTAssertTrue(result.isNoAction)
        XCTAssertEqual(recorder.checkedPairs, [])
        XCTAssertEqual(session.lastCheckAt, 100)
        XCTAssertEqual(session.lastSuccessAt, 100)
        XCTAssertEqual(session.consecutiveFailures, 0)
    }

    func testSuccessAdvancesSession() {
        var session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 100
        )
        session.recordFailure(at: 105)
        let recorder = ICEConsentFreshnessCheckRecorder(result: true)
        let executor = makeExecutor(recorder: recorder)

        let result = executor.execute(session: &session, at: 115)

        XCTAssertEqual(result.successAction?.selectedPair, candidatePair())
        XCTAssertEqual(recorder.checkedPairs, [candidatePair()])
        XCTAssertEqual(session.lastCheckAt, 115)
        XCTAssertEqual(session.lastSuccessAt, 115)
        XCTAssertNil(session.lastFailureAt)
        XCTAssertEqual(session.consecutiveFailures, 0)
    }

    func testFailureIncrementsSessionFailures() {
        var session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 100
        )
        let recorder = ICEConsentFreshnessCheckRecorder(result: false)
        let executor = makeExecutor(recorder: recorder)

        let result = executor.execute(session: &session, at: 110)

        XCTAssertEqual(result.failureAction?.selectedPair, candidatePair())
        XCTAssertEqual(recorder.checkedPairs, [candidatePair()])
        XCTAssertEqual(session.lastCheckAt, 110)
        XCTAssertEqual(session.lastSuccessAt, 100)
        XCTAssertEqual(session.lastFailureAt, 110)
        XCTAssertEqual(session.consecutiveFailures, 1)
    }

    func testTimeoutExpiredDoesNotCallChecker() {
        var session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 100
        )
        let recorder = ICEConsentFreshnessCheckRecorder(result: true)
        let executor = makeExecutor(
            policy: ICEConsentFreshnessPolicy(intervalSeconds: 100, timeoutSeconds: 30),
            recorder: recorder
        )

        let result = executor.execute(session: &session, at: 130)

        XCTAssertEqual(result.expiredAction?.selectedPair, candidatePair())
        XCTAssertEqual(result.expiredAction?.timeoutDeadline, 130)
        XCTAssertEqual(recorder.checkedPairs, [])
        XCTAssertEqual(session.lastCheckAt, 100)
        XCTAssertEqual(session.lastSuccessAt, 100)
        XCTAssertEqual(session.consecutiveFailures, 0)
    }

    func testFailureExpiredDoesNotCallChecker() {
        var session = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 100,
            lastCheckAt: 110,
            lastSuccessAt: 100,
            consecutiveFailures: 2
        )
        let recorder = ICEConsentFreshnessCheckRecorder(result: true)
        let executor = makeExecutor(
            policy: ICEConsentFreshnessPolicy(
                intervalSeconds: 10,
                timeoutSeconds: 120,
                maxConsecutiveFailures: 2
            ),
            recorder: recorder
        )

        let result = executor.execute(session: &session, at: 120)

        XCTAssertEqual(result.expiredAction?.selectedPair, candidatePair())
        XCTAssertEqual(result.expiredAction?.consecutiveFailures, 2)
        XCTAssertEqual(recorder.checkedPairs, [])
        XCTAssertEqual(session.consecutiveFailures, 2)
        XCTAssertEqual(session.lastCheckAt, 110)
    }

    func testDisabledAndNoPairDoNotCallChecker() {
        let recorder = ICEConsentFreshnessCheckRecorder(result: true)
        let disabledExecutor = makeExecutor(
            policy: ICEConsentFreshnessPolicy(
                intervalSeconds: 10,
                timeoutSeconds: 30,
                isEnabled: false
            ),
            recorder: recorder
        )
        let enabledExecutor = makeExecutor(recorder: recorder)
        var disabledSession = ICEConsentFreshnessSession(
            selectedPair: candidatePair(),
            startedAt: 100
        )
        var noPairSession = ICEConsentFreshnessSession(
            selectedPair: nil,
            startedAt: 100
        )

        let disabledResult = disabledExecutor.execute(session: &disabledSession, at: 200)
        let noPairResult = enabledExecutor.execute(session: &noPairSession, at: 200)

        XCTAssertTrue(disabledResult.isNoAction)
        XCTAssertTrue(noPairResult.isNoAction)
        XCTAssertEqual(recorder.checkedPairs, [])
        XCTAssertEqual(disabledSession.lastCheckAt, 100)
        XCTAssertEqual(noPairSession.lastCheckAt, 100)
    }

    func testCheckerReceivesSelectedPair() {
        let selectedPair = candidatePair(
            localFoundation: "selected-local",
            remoteFoundation: "selected-remote"
        )
        var session = ICEConsentFreshnessSession(
            selectedPair: selectedPair,
            startedAt: 100
        )
        let recorder = ICEConsentFreshnessCheckRecorder(result: true)
        let executor = makeExecutor(recorder: recorder)

        let result = executor.execute(session: &session, at: 110)

        XCTAssertEqual(recorder.checkedPairs, [selectedPair])
        XCTAssertEqual(result.successAction?.selectedPair, selectedPair)
    }

    private func makeExecutor(
        policy: ICEConsentFreshnessPolicy = ICEConsentFreshnessPolicy(intervalSeconds: 10, timeoutSeconds: 30),
        recorder: ICEConsentFreshnessCheckRecorder
    ) -> ICEConsentFreshnessExecutor {
        let checkConsent: ICEConsentFreshnessExecutor.ConsentCheck = { pair in
            recorder.checkConsent(pair: pair)
        }

        return ICEConsentFreshnessExecutor(policy: policy, checkConsent: checkConsent)
    }
}

private final class ICEConsentFreshnessCheckRecorder: @unchecked Sendable {
    private(set) var checkedPairs: [ICECandidatePair] = []
    var result: Bool

    init(result: Bool) {
        self.result = result
    }

    func checkConsent(pair: ICECandidatePair) -> Bool {
        checkedPairs.append(pair)
        return result
    }
}

private func candidatePair(
    localFoundation: String = "local",
    remoteFoundation: String = "remote"
) -> ICECandidatePair {
    ICECandidatePair(
        local: ICECandidate(
            foundation: localFoundation,
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 5_000,
            type: .host
        ),
        remote: ICECandidate(
            foundation: remoteFoundation,
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

private extension ICEConsentFreshnessExecutionResult {
    var isNoAction: Bool {
        guard case .noAction = self else {
            return false
        }

        return true
    }

    var successAction: ICEConsentFreshnessDueAction? {
        guard case let .success(action) = self else {
            return nil
        }

        return action
    }

    var failureAction: ICEConsentFreshnessDueAction? {
        guard case let .failure(action) = self else {
            return nil
        }

        return action
    }

    var expiredAction: ICEConsentFreshnessDueAction? {
        guard case let .expired(action) = self else {
            return nil
        }

        return action
    }
}
