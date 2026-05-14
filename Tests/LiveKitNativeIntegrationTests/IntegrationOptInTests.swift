import XCTest

final class IntegrationOptInTests: XCTestCase {
    func testIntegrationSuiteIsOptIn() throws {
        guard ProcessInfo.processInfo.environment["LIVEKIT_NATIVE_RUN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LIVEKIT_NATIVE_RUN_INTEGRATION=1 and provide a local LiveKit server to run integration tests.")
        }
    }
}
