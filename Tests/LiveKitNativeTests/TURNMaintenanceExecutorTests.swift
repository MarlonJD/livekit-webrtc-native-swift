import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class TURNMaintenanceExecutorTests: XCTestCase {
    func testDueAllocationAndPermissionRefreshAdvanceSchedulerDeadline() async {
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
        let recorder = TURNMaintenanceExecutorRecorder(
            allocationLifetimeSeconds: 120,
            permissionLifetimeSeconds: 90
        )
        let executor = TURNMaintenanceExecutor(
            policy: policy,
            refreshAllocation: recorder.refreshAllocation,
            refreshPermission: recorder.refreshPermission
        )

        let results = await executor.executeDueActions(scheduler: &scheduler, at: 190)

        XCTAssertEqual(recorder.allocationCallCount, 1)
        XCTAssertEqual(recorder.permissionIDs, ["peer"])
        XCTAssertEqual(results.map(\.action.target), [.permission("peer"), .allocation])
        XCTAssertEqual(
            results.compactMap(\.successLifetimeSeconds),
            [90, 120]
        )
        XCTAssertEqual(scheduler.dueActions(at: 259), [])
        XCTAssertEqual(scheduler.nextDeadline(after: 259), 260)
        XCTAssertEqual(scheduler.dueActions(at: 260).map(\.target), [.permission("peer")])
        XCTAssertEqual(scheduler.dueActions(at: 300).map(\.target), [.permission("peer"), .allocation])
    }

    func testNotDueActionDoesNotCallRefreshClosures() async {
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
        let recorder = TURNMaintenanceExecutorRecorder()
        let executor = TURNMaintenanceExecutor(
            policy: policy,
            refreshAllocation: recorder.refreshAllocation,
            refreshPermission: recorder.refreshPermission
        )

        let results = await executor.executeDueActions(scheduler: &scheduler, at: 179)

        XCTAssertEqual(results.count, 0)
        XCTAssertEqual(recorder.allocationCallCount, 0)
        XCTAssertEqual(recorder.permissionIDs, [])
        XCTAssertEqual(scheduler.nextDeadline(after: 179), 180)
    }

    func testRefreshErrorDoesNotAdvanceScheduler() async {
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )
        var scheduler = TURNMaintenanceScheduler(
            allocation: TURNAllocationMaintenanceState(
                allocatedAt: 100,
                lifetimeSeconds: 100,
                policy: policy
            )
        )
        let executor = TURNMaintenanceExecutor(
            policy: policy,
            refreshAllocation: {
                throw TURNMaintenanceExecutorTestError.refreshFailed
            },
            refreshPermission: { _ in
                XCTFail("Permission refresh should not be called.")
                return 100
            }
        )

        let results = await executor.executeDueActions(scheduler: &scheduler, at: 190)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.action.target, .allocation)
        XCTAssertTrue(results.first?.isFailure(TURNMaintenanceExecutorTestError.refreshFailed) == true)
        XCTAssertEqual(scheduler.nextDeadline(after: 100), 190)
        XCTAssertEqual(scheduler.dueActions(at: 190).map(\.target), [.allocation])
    }

    func testExpiredActionIsMarkedInResult() async {
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )
        var scheduler = TURNMaintenanceScheduler(
            allocation: TURNAllocationMaintenanceState(
                allocatedAt: 100,
                lifetimeSeconds: 100,
                policy: policy
            )
        )
        let recorder = TURNMaintenanceExecutorRecorder(allocationLifetimeSeconds: 100)
        let executor = TURNMaintenanceExecutor(
            policy: policy,
            refreshAllocation: recorder.refreshAllocation,
            refreshPermission: recorder.refreshPermission
        )

        let results = await executor.executeDueActions(scheduler: &scheduler, at: 200)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.action.target, .allocation)
        XCTAssertEqual(results.first?.wasExpired, true)
        XCTAssertEqual(results.first?.successLifetimeSeconds, 100)
    }
}

private final class TURNMaintenanceExecutorRecorder: @unchecked Sendable {
    private(set) var allocationCallCount = 0
    private(set) var permissionIDs: [String] = []
    var allocationLifetimeSeconds: UInt32
    var permissionLifetimeSeconds: UInt32

    init(
        allocationLifetimeSeconds: UInt32 = 100,
        permissionLifetimeSeconds: UInt32 = 100
    ) {
        self.allocationLifetimeSeconds = allocationLifetimeSeconds
        self.permissionLifetimeSeconds = permissionLifetimeSeconds
    }

    func refreshAllocation() async throws -> UInt32 {
        allocationCallCount += 1
        return allocationLifetimeSeconds
    }

    func refreshPermission(id: String) async throws -> UInt32 {
        permissionIDs.append(id)
        return permissionLifetimeSeconds
    }
}

private enum TURNMaintenanceExecutorTestError: Error, Equatable {
    case refreshFailed
}

private extension TURNMaintenanceExecutionResult {
    var successLifetimeSeconds: UInt32? {
        guard case let .success(lifetimeSeconds) = outcome else {
            return nil
        }

        return lifetimeSeconds
    }

    func isFailure<E: Error & Equatable>(_ expectedError: E) -> Bool {
        guard case let .failure(error) = outcome else {
            return false
        }

        return (error as? E) == expectedError
    }
}
