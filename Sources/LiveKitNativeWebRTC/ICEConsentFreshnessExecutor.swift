import Foundation

package struct ICEConsentFreshnessExecutor: Sendable {
    package typealias ConsentCheck = @Sendable (ICECandidatePair) -> Bool

    package var policy: ICEConsentFreshnessPolicy
    package var checkConsent: ConsentCheck

    package init(
        policy: ICEConsentFreshnessPolicy = .standard,
        checkConsent: @escaping ConsentCheck
    ) {
        self.policy = policy
        self.checkConsent = checkConsent
    }

    package func execute(
        session: inout ICEConsentFreshnessSession,
        at now: TimeInterval
    ) -> ICEConsentFreshnessExecutionResult {
        guard let action = session.dueActions(at: now, policy: policy).first else {
            return .noAction
        }

        guard !action.isExpired else {
            return .expired(action)
        }

        if checkConsent(action.selectedPair) {
            session.recordSuccess(at: now)
            return .success(action)
        }

        session.recordFailure(at: now)
        return .failure(action)
    }
}

package enum ICEConsentFreshnessExecutionResult: Sendable {
    case noAction
    case success(ICEConsentFreshnessDueAction)
    case failure(ICEConsentFreshnessDueAction)
    case expired(ICEConsentFreshnessDueAction)
}
