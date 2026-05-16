import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class TURNMaintenanceSchedulerTests: XCTestCase {
    func testDueActionsAreReturnedInDeadlineOrder() {
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )
        let allocation = TURNAllocationMaintenanceState(
            allocatedAt: 100,
            lifetimeSeconds: 100,
            policy: policy
        )
        let earlierPermission = TURNPermissionMaintenanceState(
            createdAt: 100,
            lifetimeSeconds: 100,
            policy: policy
        )
        let laterPermission = TURNPermissionMaintenanceState(
            createdAt: 140,
            lifetimeSeconds: 100,
            policy: policy
        )
        let scheduler = TURNMaintenanceScheduler(
            allocation: allocation,
            permissions: [
                "earlier": earlierPermission,
                "later": laterPermission,
            ]
        )

        let actions = scheduler.dueActions(at: 195)

        XCTAssertEqual(
            actions.map(\.target),
            [
                .permission("earlier"),
                .allocation,
            ]
        )
        XCTAssertEqual(actions.map(\.dueAt), [180, 190])
        XCTAssertEqual(actions.map(\.isExpired), [false, false])
    }

    func testNotDueActionsAreOmitted() {
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )
        let scheduler = TURNMaintenanceScheduler(
            allocation: TURNAllocationMaintenanceState(
                allocatedAt: 100,
                lifetimeSeconds: 100,
                policy: policy
            ),
            permissions: [
                "peer": TURNPermissionMaintenanceState(
                    createdAt: 100,
                    lifetimeSeconds: 100,
                    policy: policy
                ),
            ]
        )

        XCTAssertEqual(scheduler.dueActions(at: 179), [])
        XCTAssertEqual(scheduler.nextDeadline(after: 179), 180)
    }

    func testRefreshSuccessUpdatesNextDeadline() {
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )
        var scheduler = TURNMaintenanceScheduler(
            allocation: TURNAllocationMaintenanceState(
                allocatedAt: 100,
                lifetimeSeconds: 100,
                policy: policy
            ),
            permissions: [
                "peer": TURNPermissionMaintenanceState(
                    createdAt: 100,
                    lifetimeSeconds: 100,
                    policy: policy
                ),
            ]
        )

        XCTAssertEqual(scheduler.dueActions(at: 190).map(\.target), [.permission("peer"), .allocation])

        scheduler.recordPermissionRefreshSuccess(
            id: "peer",
            at: 190,
            lifetimeSeconds: 100,
            policy: policy
        )
        scheduler.recordAllocationRefreshSuccess(
            at: 190,
            lifetimeSeconds: 100,
            policy: policy
        )

        XCTAssertEqual(scheduler.dueActions(at: 249), [])
        XCTAssertEqual(scheduler.nextDeadline(after: 249), 270)
        XCTAssertEqual(scheduler.dueActions(at: 270).map(\.target), [.permission("peer")])
        XCTAssertEqual(scheduler.dueActions(at: 280).map(\.target), [.permission("peer"), .allocation])
    }

    func testExpiredStateProducesDueActionWithExpiredFlag() {
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )
        let scheduler = TURNMaintenanceScheduler(
            allocation: TURNAllocationMaintenanceState(
                allocatedAt: 100,
                lifetimeSeconds: 100,
                policy: policy
            ),
            permissions: [
                "peer": TURNPermissionMaintenanceState(
                    createdAt: 100,
                    lifetimeSeconds: 100,
                    policy: policy
                ),
            ]
        )

        let actions = scheduler.dueActions(at: 200)

        XCTAssertEqual(actions.map(\.target), [.permission("peer"), .allocation])
        XCTAssertEqual(actions.map(\.isExpired), [true, true])
        XCTAssertEqual(actions.map(\.expiresAt), [200, 200])
    }
}
