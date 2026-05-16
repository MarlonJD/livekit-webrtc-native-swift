import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class TURNMaintenanceTests: XCTestCase {
    func testAllocationRefreshDeadlineUsesSafetyMarginForNormalLifetime() {
        let state = TURNAllocationMaintenanceState(
            allocatedAt: 1_000,
            lifetimeSeconds: 600
        )

        XCTAssertEqual(state.refreshDeadline, 1_540)
        XCTAssertEqual(state.expiresAt, 1_600)
        XCTAssertFalse(state.shouldRefresh(at: 1_539.999))
        XCTAssertTrue(state.shouldRefresh(at: 1_540))
        XCTAssertFalse(state.isExpired(at: 1_599.999))
    }

    func testAllocationShortLifetimeClampsRefreshDeadlineToStart() {
        let state = TURNAllocationMaintenanceState(
            allocatedAt: 40,
            lifetimeSeconds: 30,
            jitterSeconds: 15
        )

        XCTAssertEqual(state.refreshDeadline, 40)
        XCTAssertEqual(state.expiresAt, 70)
        XCTAssertTrue(state.shouldRefresh(at: 40))
        XCTAssertFalse(state.isExpired(at: 69.999))
    }

    func testAllocationExpiredAtLifetime() {
        let state = TURNAllocationMaintenanceState(
            allocatedAt: 10,
            lifetimeSeconds: 300
        )

        XCTAssertFalse(state.isExpired(at: 309.999))
        XCTAssertTrue(state.isExpired(at: 310))
        XCTAssertFalse(state.shouldRefresh(at: 310))
    }

    func testPermissionRefreshDeadlineUsesDefaultLifetimeAndMargin() {
        let state = TURNPermissionMaintenanceState(createdAt: 200)

        XCTAssertEqual(state.lifetimeSeconds, 300)
        XCTAssertEqual(state.refreshDeadline, 440)
        XCTAssertEqual(state.expiresAt, 500)
        XCTAssertFalse(state.shouldRefresh(at: 439.999))
        XCTAssertTrue(state.shouldRefresh(at: 440))
    }

    func testRefreshPlanningIsDeterministicWithoutWallClockDependency() {
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 20,
            permissionRefreshSafetyMarginSeconds: 30,
            maximumRefreshJitterSeconds: 10
        )
        let first = TURNAllocationMaintenanceState(
            allocatedAt: 42,
            lifetimeSeconds: 120,
            policy: policy,
            jitterSeconds: 25
        )
        let second = TURNAllocationMaintenanceState(
            allocatedAt: 42,
            lifetimeSeconds: 120,
            policy: policy,
            jitterSeconds: 25
        )
        let shifted = TURNAllocationMaintenanceState(
            allocatedAt: 52,
            lifetimeSeconds: 120,
            policy: policy,
            jitterSeconds: 25
        )
        let permission = TURNPermissionMaintenanceState(
            createdAt: 42,
            lifetimeSeconds: 300,
            policy: policy,
            jitterSeconds: -5
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.refreshDeadline, 132)
        XCTAssertEqual(shifted.refreshDeadline - first.refreshDeadline, 10)
        XCTAssertEqual(permission.refreshDeadline, 312)
    }
}
