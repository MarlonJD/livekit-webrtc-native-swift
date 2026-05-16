import Foundation

package struct TURNMaintenanceExecutor: Sendable {
    package typealias AllocationRefresh = @Sendable () async throws -> UInt32
    package typealias PermissionRefresh = @Sendable (TURNMaintenanceScheduler.PermissionID) async throws -> UInt32

    package var refreshAllocation: AllocationRefresh
    package var refreshPermission: PermissionRefresh
    package var policy: TURNMaintenancePolicy
    package var jitterSeconds: TimeInterval

    package init(
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0,
        refreshAllocation: @escaping AllocationRefresh,
        refreshPermission: @escaping PermissionRefresh
    ) {
        self.refreshAllocation = refreshAllocation
        self.refreshPermission = refreshPermission
        self.policy = policy
        self.jitterSeconds = jitterSeconds
    }

    package func executeDueActions(
        scheduler: inout TURNMaintenanceScheduler,
        at now: TimeInterval
    ) async -> [TURNMaintenanceExecutionResult] {
        let actions = scheduler.dueActions(at: now)
        var results: [TURNMaintenanceExecutionResult] = []

        for action in actions {
            let result = await execute(action: action, scheduler: &scheduler, at: now)
            results.append(result)
        }

        return results
    }

    private func execute(
        action: TURNMaintenanceScheduledAction,
        scheduler: inout TURNMaintenanceScheduler,
        at now: TimeInterval
    ) async -> TURNMaintenanceExecutionResult {
        do {
            let lifetimeSeconds: UInt32

            switch action.target {
            case .allocation:
                lifetimeSeconds = try await refreshAllocation()
                scheduler.recordAllocationRefreshSuccess(
                    at: now,
                    lifetimeSeconds: lifetimeSeconds,
                    policy: policy,
                    jitterSeconds: jitterSeconds
                )
            case let .permission(id):
                lifetimeSeconds = try await refreshPermission(id)
                scheduler.recordPermissionRefreshSuccess(
                    id: id,
                    at: now,
                    lifetimeSeconds: lifetimeSeconds,
                    policy: policy,
                    jitterSeconds: jitterSeconds
                )
            }

            return TURNMaintenanceExecutionResult(
                action: action,
                outcome: .success(lifetimeSeconds: lifetimeSeconds)
            )
        } catch {
            return TURNMaintenanceExecutionResult(
                action: action,
                outcome: .failure(error)
            )
        }
    }
}

package struct TURNMaintenanceExecutionResult {
    package var action: TURNMaintenanceScheduledAction
    package var wasExpired: Bool
    package var outcome: TURNMaintenanceExecutionOutcome

    package init(
        action: TURNMaintenanceScheduledAction,
        outcome: TURNMaintenanceExecutionOutcome
    ) {
        self.action = action
        self.wasExpired = action.isExpired
        self.outcome = outcome
    }
}

package enum TURNMaintenanceExecutionOutcome {
    case success(lifetimeSeconds: UInt32)
    case failure(any Error)
}
