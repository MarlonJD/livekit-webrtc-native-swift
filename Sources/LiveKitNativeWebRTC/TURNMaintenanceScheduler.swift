import Foundation

package struct TURNMaintenanceScheduledAction: Equatable, Sendable {
    package enum Target: Equatable, Sendable {
        case allocation
        case permission(String)
    }

    package var target: Target
    package var dueAt: TimeInterval
    package var expiresAt: TimeInterval
    package var isExpired: Bool

    package init(
        target: Target,
        dueAt: TimeInterval,
        expiresAt: TimeInterval,
        isExpired: Bool
    ) {
        self.target = target
        self.dueAt = dueAt
        self.expiresAt = expiresAt
        self.isExpired = isExpired
    }
}

package struct TURNMaintenanceScheduler: Equatable, Sendable {
    package typealias PermissionID = String

    package var allocation: TURNAllocationMaintenanceState?
    package var permissions: [PermissionID: TURNPermissionMaintenanceState]

    package init(
        allocation: TURNAllocationMaintenanceState? = nil,
        permissions: [PermissionID: TURNPermissionMaintenanceState] = [:]
    ) {
        self.allocation = allocation
        self.permissions = permissions
    }

    package func dueActions(at now: TimeInterval) -> [TURNMaintenanceScheduledAction] {
        var actions: [TURNMaintenanceScheduledAction] = []

        if let allocation, now >= allocation.refreshDeadline {
            actions.append(
                TURNMaintenanceScheduledAction(
                    target: .allocation,
                    dueAt: allocation.refreshDeadline,
                    expiresAt: allocation.expiresAt,
                    isExpired: allocation.isExpired(at: now)
                )
            )
        }

        for (id, permission) in permissions where now >= permission.refreshDeadline {
            actions.append(
                TURNMaintenanceScheduledAction(
                    target: .permission(id),
                    dueAt: permission.refreshDeadline,
                    expiresAt: permission.expiresAt,
                    isExpired: permission.isExpired(at: now)
                )
            )
        }

        return actions.sorted(by: scheduledActionSort)
    }

    package func nextDeadline(after now: TimeInterval) -> TimeInterval? {
        var deadlines: [TimeInterval] = []

        if let allocation, allocation.refreshDeadline > now {
            deadlines.append(allocation.refreshDeadline)
        }

        deadlines.append(contentsOf: permissions.values.compactMap { permission in
            permission.refreshDeadline > now ? permission.refreshDeadline : nil
        })

        return deadlines.min()
    }

    package mutating func setAllocation(_ state: TURNAllocationMaintenanceState?) {
        allocation = state
    }

    package mutating func setPermission(
        _ state: TURNPermissionMaintenanceState,
        id: PermissionID
    ) {
        permissions[id] = state
    }

    package mutating func removePermission(id: PermissionID) {
        permissions[id] = nil
    }

    package mutating func recordAllocationRefreshSuccess(
        at now: TimeInterval,
        lifetimeSeconds: UInt32,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0
    ) {
        allocation = TURNAllocationMaintenanceState(
            allocatedAt: now,
            lifetimeSeconds: lifetimeSeconds,
            policy: policy,
            jitterSeconds: jitterSeconds
        )
    }

    package mutating func recordPermissionRefreshSuccess(
        id: PermissionID,
        at now: TimeInterval,
        lifetimeSeconds: UInt32 = TURNMaintenancePolicy.defaultPermissionLifetimeSeconds,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0
    ) {
        permissions[id] = TURNPermissionMaintenanceState(
            createdAt: now,
            lifetimeSeconds: lifetimeSeconds,
            policy: policy,
            jitterSeconds: jitterSeconds
        )
    }
}

private func scheduledActionSort(
    _ lhs: TURNMaintenanceScheduledAction,
    _ rhs: TURNMaintenanceScheduledAction
) -> Bool {
    if lhs.dueAt != rhs.dueAt {
        return lhs.dueAt < rhs.dueAt
    }

    if lhs.expiresAt != rhs.expiresAt {
        return lhs.expiresAt < rhs.expiresAt
    }

    return scheduledActionTargetSortKey(lhs.target) < scheduledActionTargetSortKey(rhs.target)
}

private func scheduledActionTargetSortKey(
    _ target: TURNMaintenanceScheduledAction.Target
) -> String {
    switch target {
    case .allocation:
        return "0:"
    case let .permission(id):
        return "1:\(id)"
    }
}
