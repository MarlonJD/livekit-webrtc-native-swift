import XCTest
@testable import LiveKitNative

final class ProductionReadinessTests: XCTestCase {
    func testProductionReadinessIsExplicitAboutCurrentBlockers() {
        let readiness = LiveKitNative.productionReadiness

        XCTAssertEqual(readiness.status, .developerPreview)
        XCTAssertFalse(readiness.isProductionReady)
        XCTAssertFalse(readiness.blockers.isEmpty)
        XCTAssertTrue(readiness.blockers.contains { $0.contains("DTLS-SRTP") })
    }

    func testAssertProductionReadyFailsUntilBlockersAreCleared() {
        XCTAssertThrowsError(try LiveKitNative.assertProductionReady()) { error in
            guard case let LiveKitNativeError.productionReadinessFailed(blockers) = error else {
                return XCTFail("Expected productionReadinessFailed error.")
            }
            XCTAssertFalse(blockers.isEmpty)
        }
    }
}
