import Foundation

package struct ICEConsentFreshnessPolicy: Equatable, Sendable {
    package static let defaultIntervalSeconds: TimeInterval = 15
    package static let defaultTimeoutSeconds: TimeInterval = 30
    package static let defaultMaxConsecutiveFailures = 6

    package static let standard = ICEConsentFreshnessPolicy()
    package static let disabled = ICEConsentFreshnessPolicy(isEnabled: false)

    package var intervalSeconds: TimeInterval
    package var timeoutSeconds: TimeInterval
    package var maxConsecutiveFailures: Int
    package var jitterSeconds: TimeInterval?
    package var isEnabled: Bool

    package init(
        intervalSeconds: TimeInterval = Self.defaultIntervalSeconds,
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds,
        maxConsecutiveFailures: Int = Self.defaultMaxConsecutiveFailures,
        jitterSeconds: TimeInterval? = nil,
        isEnabled: Bool = true
    ) {
        self.intervalSeconds = max(0, intervalSeconds)
        self.timeoutSeconds = max(0, timeoutSeconds)
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
        self.jitterSeconds = jitterSeconds.map { max(0, $0) }
        self.isEnabled = isEnabled
    }

    package func nextCheckDeadline(after lastCheckAt: TimeInterval) -> TimeInterval {
        lastCheckAt + max(0, intervalSeconds - effectiveJitterSeconds)
    }

    package func timeoutDeadline(after lastSuccessAt: TimeInterval) -> TimeInterval {
        lastSuccessAt + timeoutSeconds
    }

    package var effectiveJitterSeconds: TimeInterval {
        jitterSeconds ?? 0
    }
}

package struct ICEConsentFreshnessDueAction: Equatable, Sendable {
    package var selectedPair: ICECandidatePair
    package var dueAt: TimeInterval
    package var nextCheckDeadline: TimeInterval
    package var timeoutDeadline: TimeInterval
    package var consecutiveFailures: Int
    package var isExpired: Bool

    package init(
        selectedPair: ICECandidatePair,
        dueAt: TimeInterval,
        nextCheckDeadline: TimeInterval,
        timeoutDeadline: TimeInterval,
        consecutiveFailures: Int,
        isExpired: Bool
    ) {
        self.selectedPair = selectedPair
        self.dueAt = dueAt
        self.nextCheckDeadline = nextCheckDeadline
        self.timeoutDeadline = timeoutDeadline
        self.consecutiveFailures = consecutiveFailures
        self.isExpired = isExpired
    }
}

package struct ICEConsentFreshnessSession: Equatable, Sendable {
    package var selectedPair: ICECandidatePair?
    package var startedAt: TimeInterval
    package var lastCheckAt: TimeInterval
    package var lastSuccessAt: TimeInterval
    package var lastFailureAt: TimeInterval?
    package private(set) var consecutiveFailures: Int

    package init(
        selectedPair: ICECandidatePair?,
        startedAt: TimeInterval,
        lastCheckAt: TimeInterval? = nil,
        lastSuccessAt: TimeInterval? = nil,
        lastFailureAt: TimeInterval? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.selectedPair = selectedPair
        self.startedAt = startedAt
        self.lastCheckAt = lastCheckAt ?? startedAt
        self.lastSuccessAt = lastSuccessAt ?? startedAt
        self.lastFailureAt = lastFailureAt
        self.consecutiveFailures = max(0, consecutiveFailures)
    }

    package func nextCheckDeadline(policy: ICEConsentFreshnessPolicy = .standard) -> TimeInterval {
        policy.nextCheckDeadline(after: lastCheckAt)
    }

    package func timeoutDeadline(policy: ICEConsentFreshnessPolicy = .standard) -> TimeInterval {
        policy.timeoutDeadline(after: lastSuccessAt)
    }

    package func isExpired(
        at now: TimeInterval,
        policy: ICEConsentFreshnessPolicy = .standard
    ) -> Bool {
        consecutiveFailures >= policy.maxConsecutiveFailures ||
            now >= timeoutDeadline(policy: policy)
    }

    package func dueActions(
        at now: TimeInterval,
        policy: ICEConsentFreshnessPolicy = .standard
    ) -> [ICEConsentFreshnessDueAction] {
        guard policy.isEnabled, let selectedPair else {
            return []
        }

        let nextCheckDeadline = nextCheckDeadline(policy: policy)
        let timeoutDeadline = timeoutDeadline(policy: policy)
        let dueAt = min(nextCheckDeadline, timeoutDeadline)
        guard now >= dueAt else {
            return []
        }

        return [
            ICEConsentFreshnessDueAction(
                selectedPair: selectedPair,
                dueAt: dueAt,
                nextCheckDeadline: nextCheckDeadline,
                timeoutDeadline: timeoutDeadline,
                consecutiveFailures: consecutiveFailures,
                isExpired: isExpired(at: now, policy: policy)
            ),
        ]
    }

    package mutating func recordSuccess(at now: TimeInterval) {
        lastCheckAt = now
        lastSuccessAt = now
        lastFailureAt = nil
        consecutiveFailures = 0
    }

    package mutating func recordFailure(at now: TimeInterval) {
        lastCheckAt = now
        lastFailureAt = now
        consecutiveFailures += 1
    }
}
