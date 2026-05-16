import Foundation

package struct TURNMaintenancePolicy: Equatable, Sendable {
    package static let defaultAllocationRefreshSafetyMarginSeconds: TimeInterval = 60
    package static let defaultPermissionLifetimeSeconds: UInt32 = 300
    package static let defaultPermissionRefreshSafetyMarginSeconds: TimeInterval = 60
    package static let defaultMaximumRefreshJitterSeconds: TimeInterval = 15

    package static let standard = TURNMaintenancePolicy()

    package var allocationRefreshSafetyMarginSeconds: TimeInterval
    package var permissionRefreshSafetyMarginSeconds: TimeInterval
    package var maximumRefreshJitterSeconds: TimeInterval

    package init(
        allocationRefreshSafetyMarginSeconds: TimeInterval = Self.defaultAllocationRefreshSafetyMarginSeconds,
        permissionRefreshSafetyMarginSeconds: TimeInterval = Self.defaultPermissionRefreshSafetyMarginSeconds,
        maximumRefreshJitterSeconds: TimeInterval = Self.defaultMaximumRefreshJitterSeconds
    ) {
        self.allocationRefreshSafetyMarginSeconds = max(0, allocationRefreshSafetyMarginSeconds)
        self.permissionRefreshSafetyMarginSeconds = max(0, permissionRefreshSafetyMarginSeconds)
        self.maximumRefreshJitterSeconds = max(0, maximumRefreshJitterSeconds)
    }

    package func allocationRefreshDeadline(
        allocatedAt: TimeInterval,
        lifetimeSeconds: UInt32,
        jitterSeconds: TimeInterval = 0
    ) -> TimeInterval {
        turnRefreshDeadline(
            startedAt: allocatedAt,
            lifetimeSeconds: lifetimeSeconds,
            safetyMarginSeconds: allocationRefreshSafetyMarginSeconds,
            jitterSeconds: jitterSeconds,
            maximumJitterSeconds: maximumRefreshJitterSeconds
        )
    }

    package func permissionRefreshDeadline(
        createdAt: TimeInterval,
        lifetimeSeconds: UInt32 = Self.defaultPermissionLifetimeSeconds,
        jitterSeconds: TimeInterval = 0
    ) -> TimeInterval {
        turnRefreshDeadline(
            startedAt: createdAt,
            lifetimeSeconds: lifetimeSeconds,
            safetyMarginSeconds: permissionRefreshSafetyMarginSeconds,
            jitterSeconds: jitterSeconds,
            maximumJitterSeconds: maximumRefreshJitterSeconds
        )
    }
}

package struct TURNAllocationMaintenanceState: Equatable, Sendable {
    package var allocatedAt: TimeInterval
    package var lifetimeSeconds: UInt32
    package var refreshDeadline: TimeInterval
    package var expiresAt: TimeInterval

    package init(
        allocatedAt: TimeInterval,
        lifetimeSeconds: UInt32,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0
    ) {
        self.allocatedAt = allocatedAt
        self.lifetimeSeconds = lifetimeSeconds
        self.refreshDeadline = policy.allocationRefreshDeadline(
            allocatedAt: allocatedAt,
            lifetimeSeconds: lifetimeSeconds,
            jitterSeconds: jitterSeconds
        )
        self.expiresAt = allocatedAt + TimeInterval(lifetimeSeconds)
    }

    package func shouldRefresh(at now: TimeInterval) -> Bool {
        now >= refreshDeadline && !isExpired(at: now)
    }

    package func isExpired(at now: TimeInterval) -> Bool {
        now >= expiresAt
    }
}

package struct TURNPermissionMaintenanceState: Equatable, Sendable {
    package var createdAt: TimeInterval
    package var lifetimeSeconds: UInt32
    package var refreshDeadline: TimeInterval
    package var expiresAt: TimeInterval

    package init(
        createdAt: TimeInterval,
        lifetimeSeconds: UInt32 = TURNMaintenancePolicy.defaultPermissionLifetimeSeconds,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0
    ) {
        self.createdAt = createdAt
        self.lifetimeSeconds = lifetimeSeconds
        self.refreshDeadline = policy.permissionRefreshDeadline(
            createdAt: createdAt,
            lifetimeSeconds: lifetimeSeconds,
            jitterSeconds: jitterSeconds
        )
        self.expiresAt = createdAt + TimeInterval(lifetimeSeconds)
    }

    package func shouldRefresh(at now: TimeInterval) -> Bool {
        now >= refreshDeadline && !isExpired(at: now)
    }

    package func isExpired(at now: TimeInterval) -> Bool {
        now >= expiresAt
    }
}

private func turnRefreshDeadline(
    startedAt: TimeInterval,
    lifetimeSeconds: UInt32,
    safetyMarginSeconds: TimeInterval,
    jitterSeconds: TimeInterval,
    maximumJitterSeconds: TimeInterval
) -> TimeInterval {
    let requestedJitterSeconds = max(0, jitterSeconds)
    let effectiveJitterSeconds = min(requestedJitterSeconds, maximumJitterSeconds)
    let refreshOffset = max(0, TimeInterval(lifetimeSeconds) - safetyMarginSeconds - effectiveJitterSeconds)

    return startedAt + refreshOffset
}
