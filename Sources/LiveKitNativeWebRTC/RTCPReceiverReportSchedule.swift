import Foundation

package struct RTCPReceiverReportSchedulePolicy: Equatable, Sendable {
    package static let standard = RTCPReceiverReportSchedulePolicy()
    package static let disabled = RTCPReceiverReportSchedulePolicy(isEnabled: false)

    package var intervalSeconds: TimeInterval
    package var isEnabled: Bool

    package init(
        intervalSeconds: TimeInterval = 5,
        isEnabled: Bool = true
    ) {
        self.intervalSeconds = max(0.001, intervalSeconds)
        self.isEnabled = isEnabled
    }
}

package struct RTCPReceiverReportScheduleSession: Equatable, Sendable {
    package var startedAt: TimeInterval
    package var lastAttemptAt: TimeInterval?

    package init(
        startedAt: TimeInterval,
        lastAttemptAt: TimeInterval? = nil
    ) {
        self.startedAt = startedAt
        self.lastAttemptAt = lastAttemptAt
    }

    package func nextReportDeadline(policy: RTCPReceiverReportSchedulePolicy) -> TimeInterval {
        (lastAttemptAt ?? startedAt) + policy.intervalSeconds
    }

    package func dueAction(
        at now: TimeInterval,
        policy: RTCPReceiverReportSchedulePolicy
    ) -> RTCPReceiverReportScheduleAction? {
        guard policy.isEnabled else {
            return nil
        }

        let deadline = nextReportDeadline(policy: policy)
        guard now >= deadline else {
            return nil
        }

        return RTCPReceiverReportScheduleAction(deadline: deadline, now: now)
    }

    package mutating func recordAttempt(at now: TimeInterval) {
        lastAttemptAt = now
    }
}

package struct RTCPReceiverReportScheduleAction: Equatable, Sendable {
    package var deadline: TimeInterval
    package var now: TimeInterval

    package init(deadline: TimeInterval, now: TimeInterval) {
        self.deadline = deadline
        self.now = now
    }
}
