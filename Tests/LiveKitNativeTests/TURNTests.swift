import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class TURNTests: XCTestCase {
    func testParsesUnauthenticatedAllocateSuccessResponse() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 1, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            XCTAssertEqual(request.type, .allocateRequest)
            XCTAssertEqual(request.transactionID, transactionID)
            XCTAssertEqual(request.firstAttribute(.requestedTransport)?.requestedTransportProtocol, .udp)
            XCTAssertNil(request.firstAttribute(.username))
            XCTAssertNil(request.firstAttribute(.messageIntegrity))
            XCTAssertNotNil(request.firstAttribute(.fingerprint))
            XCTAssertTrue(try request.validatesFingerprint())

            let response = STUNMessage(
                type: .allocateSuccessResponse,
                transactionID: request.transactionID,
                attributes: [
                    try .xorRelayedAddressIPv4(
                        address: "192.0.2.44",
                        port: 49_152,
                        transactionID: request.transactionID
                    ),
                    .lifetime(seconds: 1_200),
                ]
            )
            return try response.encoded(includeFingerprint: true)
        }

        let client = TURNAllocationClient(transport: transport)
        let result = try client.allocate(
            transactionID: transactionID,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(result.relayedAddress, STUNMappedAddress(address: "192.0.2.44", port: 49_152))
        XCTAssertEqual(result.lifetimeSeconds, 1_200)
        XCTAssertEqual(result.response.type, .allocateSuccessResponse)
    }

    func testPerformsOneLongTermCredentialChallengeRoundTrip() throws {
        let unauthenticatedTransactionID = try STUNTransactionID(bytes: Array(repeating: 2, count: 12))
        let authenticatedTransactionID = try STUNTransactionID(bytes: Array(repeating: 3, count: 12))
        let recorder = TURNRequestRecorder()
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let attempt = recorder.nextAttempt()
            let request = try STUNMessage(decoding: requestData)

            if attempt == 1 {
                XCTAssertEqual(request.transactionID, unauthenticatedTransactionID)
                XCTAssertNil(request.firstAttribute(.messageIntegrity))

                let response = STUNMessage(
                    type: .allocateErrorResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        .errorCode(401, reason: "Unauthorized"),
                        .realm("turn.example.test"),
                        .nonce("nonce-1"),
                    ]
                )
                return try response.encoded(includeFingerprint: true)
            }

            XCTAssertEqual(request.transactionID, authenticatedTransactionID)
            XCTAssertEqual(try request.firstAttribute(.username)?.stringValue, "relay-user")
            XCTAssertEqual(try request.firstAttribute(.realm)?.stringValue, "turn.example.test")
            XCTAssertEqual(try request.firstAttribute(.nonce)?.stringValue, "nonce-1")
            XCTAssertNotNil(request.firstAttribute(.messageIntegrity))
            XCTAssertNotNil(request.firstAttribute(.fingerprint))
            XCTAssertTrue(try request.validatesMessageIntegrity(key: TURNLongTermCredential.messageIntegrityKey(
                username: "relay-user",
                realm: "turn.example.test",
                password: "relay-password"
            )))
            XCTAssertTrue(try request.validatesFingerprint())

            let response = STUNMessage(
                type: .allocateSuccessResponse,
                transactionID: request.transactionID,
                attributes: [
                    try .xorRelayedAddressIPv4(
                        address: "198.51.100.7",
                        port: 61_000,
                        transactionID: request.transactionID
                    ),
                ]
            )
            return try response.encoded(
                messageIntegrityKey: TURNLongTermCredential.messageIntegrityKey(
                    username: "relay-user",
                    realm: "turn.example.test",
                    password: "relay-password"
                ),
                includeFingerprint: true
            )
        }

        let client = TURNAllocationClient(transport: transport)
        let result = try client.allocate(
            username: "relay-user",
            password: "relay-password",
            transactionID: unauthenticatedTransactionID,
            authenticatedTransactionID: authenticatedTransactionID,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(result.relayedAddress, STUNMappedAddress(address: "198.51.100.7", port: 61_000))
        XCTAssertEqual(result.lifetimeSeconds, 600)
        XCTAssertEqual(recorder.attemptCount, 2)
    }

    func testRejectsMismatchedAllocateResponseTransactionID() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 4, count: 12))
        let wrongTransactionID = try STUNTransactionID(bytes: Array(repeating: 5, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { _ in
            let response = STUNMessage(
                type: .allocateSuccessResponse,
                transactionID: wrongTransactionID,
                attributes: [
                    try .xorRelayedAddressIPv4(
                        address: "192.0.2.45",
                        port: 49_153,
                        transactionID: wrongTransactionID
                    ),
                ]
            )
            return try response.encoded()
        }
        let client = TURNAllocationClient(transport: transport)

        XCTAssertThrowsError(try client.allocate(transactionID: transactionID)) { error in
            XCTAssertEqual(error as? TURNAllocationError, .transactionMismatch)
        }
    }

    func testRejectsAllocateSuccessResponseMissingRelayedAddress() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 6, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)
            return try STUNMessage(
                type: .allocateSuccessResponse,
                transactionID: request.transactionID,
                attributes: [.lifetime(seconds: 300)]
            ).encoded()
        }
        let client = TURNAllocationClient(transport: transport)

        XCTAssertThrowsError(try client.allocate(transactionID: transactionID)) { error in
            XCTAssertEqual(error as? TURNAllocationError, .missingRelayedAddress)
        }
    }

    func testRejectsInvalidAuthenticatedAllocateResponseMessageIntegrity() throws {
        let unauthenticatedTransactionID = try STUNTransactionID(bytes: Array(repeating: 8, count: 12))
        let authenticatedTransactionID = try STUNTransactionID(bytes: Array(repeating: 9, count: 12))
        let recorder = TURNRequestRecorder()
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let attempt = recorder.nextAttempt()
            let request = try STUNMessage(decoding: requestData)

            if attempt == 1 {
                return try STUNMessage(
                    type: .allocateErrorResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        .errorCode(401, reason: "Unauthorized"),
                        .realm("turn.example.test"),
                        .nonce("nonce-1"),
                    ]
                ).encoded()
            }

            return try STUNMessage(
                type: .allocateSuccessResponse,
                transactionID: request.transactionID,
                attributes: [
                    try .xorRelayedAddressIPv4(
                        address: "198.51.100.8",
                        port: 61_001,
                        transactionID: request.transactionID
                    ),
                ]
            ).encoded(
                messageIntegrityKey: TURNLongTermCredential.messageIntegrityKey(
                    username: "relay-user",
                    realm: "turn.example.test",
                    password: "wrong-password"
                )
            )
        }
        let client = TURNAllocationClient(transport: transport)

        XCTAssertThrowsError(
            try client.allocate(
                username: "relay-user",
                password: "relay-password",
                transactionID: unauthenticatedTransactionID,
                authenticatedTransactionID: authenticatedTransactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNAllocationError, .invalidMessageIntegrity)
        }
    }

    func testRejectsChallengeWithoutCredentials() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 7, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)
            return try STUNMessage(
                type: .allocateErrorResponse,
                transactionID: request.transactionID,
                attributes: [
                    .errorCode(401, reason: "Unauthorized"),
                    .realm("turn.example.test"),
                    .nonce("nonce-1"),
                ]
            ).encoded()
        }
        let client = TURNAllocationClient(transport: transport)

        XCTAssertThrowsError(try client.allocate(transactionID: transactionID)) { error in
            XCTAssertEqual(error as? TURNAllocationError, .authenticationChallengeWithoutCredentials)
        }
    }

    func testParsesErrorCodeAttribute() throws {
        let attribute = STUNAttribute.errorCode(401, reason: "Unauthorized")

        XCTAssertEqual(try attribute.errorCodeValue, STUNErrorCode(code: 401, reason: "Unauthorized"))
    }

    func testRejectsMalformedErrorCodeAttribute() throws {
        let attribute = STUNAttribute(type: .errorCode, value: Data([0, 1, 9, 255]))

        XCTAssertThrowsError(try attribute.errorCodeValue) { error in
            XCTAssertEqual(error as? STUNError, .invalidErrorCodeAttribute)
        }
    }
}

private struct FakeTURNSTUNDatagramTransport: STUNDatagramTransport {
    var handler: @Sendable (Data) throws -> Data

    func send(_ data: Data) throws -> Data {
        try handler(data)
    }
}

private final class TURNRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func nextAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        return attempts
    }
}
