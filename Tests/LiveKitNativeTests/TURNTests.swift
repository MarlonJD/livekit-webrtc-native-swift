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

    func testRefreshSendsSignedRequestAndParsesDeallocationSuccess() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 10, count: 12))
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: "relay-user",
            realm: "turn.example.test",
            password: "relay-password"
        )
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            XCTAssertEqual(request.type, .refreshRequest)
            XCTAssertEqual(request.transactionID, transactionID)
            XCTAssertEqual(request.firstAttribute(.lifetime)?.uint32Value, 0)
            XCTAssertEqual(try request.firstAttribute(.username)?.stringValue, "relay-user")
            XCTAssertEqual(try request.firstAttribute(.realm)?.stringValue, "turn.example.test")
            XCTAssertEqual(try request.firstAttribute(.nonce)?.stringValue, "nonce-1")
            XCTAssertNotNil(request.firstAttribute(.messageIntegrity))
            XCTAssertNotNil(request.firstAttribute(.fingerprint))
            XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
            XCTAssertTrue(try request.validatesFingerprint())

            return try STUNMessage(
                type: .refreshSuccessResponse,
                transactionID: request.transactionID,
                attributes: [.lifetime(seconds: 0)]
            ).encoded(
                messageIntegrityKey: key,
                includeFingerprint: true
            )
        }

        let client = TURNRefreshClient(transport: transport)
        let result = try client.refresh(
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            password: "relay-password",
            lifetimeSeconds: 0,
            transactionID: transactionID,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(result.lifetimeSeconds, 0)
        XCTAssertEqual(result.response.type, .refreshSuccessResponse)
    }

    func testRefreshDefaultsMissingSuccessLifetimeToTenMinutes() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 11, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            return try STUNMessage(
                type: .refreshSuccessResponse,
                transactionID: request.transactionID
            ).encoded()
        }

        let client = TURNRefreshClient(transport: transport)
        let result = try client.refresh(
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            password: "relay-password",
            transactionID: transactionID
        )

        XCTAssertEqual(result.lifetimeSeconds, 600)
    }

    func testRejectsMismatchedRefreshResponseTransactionID() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 12, count: 12))
        let wrongTransactionID = try STUNTransactionID(bytes: Array(repeating: 13, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { _ in
            try STUNMessage(
                type: .refreshSuccessResponse,
                transactionID: wrongTransactionID,
                attributes: [.lifetime(seconds: 600)]
            ).encoded()
        }
        let client = TURNRefreshClient(transport: transport)

        XCTAssertThrowsError(
            try client.refresh(
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNRefreshError, .transactionMismatch)
        }
    }

    func testMapsRefreshErrorResponseCode() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 14, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            return try STUNMessage(
                type: .refreshErrorResponse,
                transactionID: request.transactionID,
                attributes: [.errorCode(438, reason: "Stale Nonce")]
            ).encoded()
        }
        let client = TURNRefreshClient(transport: transport)

        XCTAssertThrowsError(
            try client.refresh(
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNRefreshError, .refreshFailed(438))
        }
    }

    func testRejectsInvalidRefreshSuccessLifetime() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 15, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            return try STUNMessage(
                type: .refreshSuccessResponse,
                transactionID: request.transactionID,
                attributes: [STUNAttribute(type: .lifetime, value: Data([0, 1]))]
            ).encoded()
        }
        let client = TURNRefreshClient(transport: transport)

        XCTAssertThrowsError(
            try client.refresh(
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNRefreshError, .invalidLifetime)
        }
    }

    func testRejectsInvalidRefreshResponseMessageIntegrity() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 16, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            return try STUNMessage(
                type: .refreshSuccessResponse,
                transactionID: request.transactionID,
                attributes: [.lifetime(seconds: 600)]
            ).encoded(
                messageIntegrityKey: TURNLongTermCredential.messageIntegrityKey(
                    username: "relay-user",
                    realm: "turn.example.test",
                    password: "wrong-password"
                )
            )
        }
        let client = TURNRefreshClient(transport: transport)

        XCTAssertThrowsError(
            try client.refresh(
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNRefreshError, .invalidMessageIntegrity)
        }
    }

    func testRejectsInvalidRefreshResponseFingerprint() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 17, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)
            var response = try STUNMessage(
                type: .refreshSuccessResponse,
                transactionID: request.transactionID,
                attributes: [.lifetime(seconds: 600)]
            ).encoded(includeFingerprint: true)
            response[response.count - 1] ^= 0x01
            return response
        }
        let client = TURNRefreshClient(transport: transport)

        XCTAssertThrowsError(
            try client.refresh(
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNRefreshError, .invalidFingerprint)
        }
    }

    func testXORPeerAddressIPv4RoundTrips() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 18, count: 12))
        let attribute = try STUNAttribute.xorPeerAddressIPv4(
            address: "203.0.113.9",
            port: 54_321,
            transactionID: transactionID
        )

        XCTAssertEqual(attribute.type, STUNAttributeType.xorPeerAddress.rawValue)
        XCTAssertEqual(try attribute.xorPeerAddressValue, STUNMappedAddress(address: "203.0.113.9", port: 54_321))
    }

    func testCreatePermissionSendsSignedRequestAndParsesSuccess() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 19, count: 12))
        let peerAddresses = [
            STUNMappedAddress(address: "203.0.113.10", port: 5_000),
            STUNMappedAddress(address: "198.51.100.20", port: 5_001),
        ]
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: "relay-user",
            realm: "turn.example.test",
            password: "relay-password"
        )
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            XCTAssertEqual(request.type, .createPermissionRequest)
            XCTAssertEqual(request.transactionID, transactionID)
            XCTAssertEqual(try request.firstAttribute(.username)?.stringValue, "relay-user")
            XCTAssertEqual(try request.firstAttribute(.realm)?.stringValue, "turn.example.test")
            XCTAssertEqual(try request.firstAttribute(.nonce)?.stringValue, "nonce-1")
            XCTAssertNotNil(request.firstAttribute(.messageIntegrity))
            XCTAssertNotNil(request.firstAttribute(.fingerprint))
            XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
            XCTAssertTrue(try request.validatesFingerprint())

            let decodedPeers = try request.attributes
                .filter { $0.type == STUNAttributeType.xorPeerAddress.rawValue }
                .map { try XCTUnwrap(try $0.xorPeerAddressValue) }
            XCTAssertEqual(decodedPeers, peerAddresses)

            return try STUNMessage(
                type: .createPermissionSuccessResponse,
                transactionID: request.transactionID
            ).encoded(
                messageIntegrityKey: key,
                includeFingerprint: true
            )
        }

        let client = TURNCreatePermissionClient(transport: transport)
        let result = try client.createPermission(
            peerAddresses: peerAddresses,
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            password: "relay-password",
            transactionID: transactionID,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(result.response.type, .createPermissionSuccessResponse)
    }

    func testRejectsMismatchedCreatePermissionResponseTransactionID() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 20, count: 12))
        let wrongTransactionID = try STUNTransactionID(bytes: Array(repeating: 21, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { _ in
            try STUNMessage(
                type: .createPermissionSuccessResponse,
                transactionID: wrongTransactionID
            ).encoded()
        }
        let client = TURNCreatePermissionClient(transport: transport)

        XCTAssertThrowsError(
            try client.createPermission(
                peerAddresses: [STUNMappedAddress(address: "203.0.113.11", port: 5_002)],
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNCreatePermissionError, .transactionMismatch)
        }
    }

    func testMapsCreatePermissionErrorResponseCode() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 22, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            return try STUNMessage(
                type: .createPermissionErrorResponse,
                transactionID: request.transactionID,
                attributes: [.errorCode(403, reason: "Forbidden")]
            ).encoded()
        }
        let client = TURNCreatePermissionClient(transport: transport)

        XCTAssertThrowsError(
            try client.createPermission(
                peerAddresses: [STUNMappedAddress(address: "203.0.113.12", port: 5_003)],
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNCreatePermissionError, .createPermissionFailed(403))
        }
    }

    func testChannelBindRequestFactoryBuildsSignedMessagePrimitives() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 23, count: 12))
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: "relay-user",
            realm: "turn.example.test",
            password: "relay-password"
        )
        let message = try TURNChannelBindRequestFactory.makeChannelBindRequest(
            channelNumber: 0x4000,
            peerAddress: STUNMappedAddress(address: "203.0.113.13", port: 5_004),
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            transactionID: transactionID
        )
        let decoded = try STUNMessage(decoding: try message.encoded(
            messageIntegrityKey: key,
            includeFingerprint: true
        ))

        XCTAssertEqual(decoded.type, .channelBindRequest)
        XCTAssertEqual(decoded.firstAttribute(.channelNumber)?.channelNumberValue, 0x4000)
        XCTAssertEqual(
            try decoded.firstAttribute(.xorPeerAddress)?.xorPeerAddressValue,
            STUNMappedAddress(address: "203.0.113.13", port: 5_004)
        )
        XCTAssertEqual(try decoded.firstAttribute(.username)?.stringValue, "relay-user")
        XCTAssertTrue(try decoded.validatesMessageIntegrity(key: key))
        XCTAssertTrue(try decoded.validatesFingerprint())
    }

    func testChannelBindSendsSignedRequestAndParsesSuccess() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 24, count: 12))
        let peerAddress = STUNMappedAddress(address: "203.0.113.14", port: 5_005)
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: "relay-user",
            realm: "turn.example.test",
            password: "relay-password"
        )
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            XCTAssertEqual(request.type, .channelBindRequest)
            XCTAssertEqual(request.transactionID, transactionID)
            XCTAssertEqual(request.firstAttribute(.channelNumber)?.channelNumberValue, 0x4001)
            XCTAssertEqual(try request.firstAttribute(.xorPeerAddress)?.xorPeerAddressValue, peerAddress)
            XCTAssertEqual(try request.firstAttribute(.username)?.stringValue, "relay-user")
            XCTAssertEqual(try request.firstAttribute(.realm)?.stringValue, "turn.example.test")
            XCTAssertEqual(try request.firstAttribute(.nonce)?.stringValue, "nonce-1")
            XCTAssertNotNil(request.firstAttribute(.messageIntegrity))
            XCTAssertNotNil(request.firstAttribute(.fingerprint))
            XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
            XCTAssertTrue(try request.validatesFingerprint())

            return try STUNMessage(
                type: .channelBindSuccessResponse,
                transactionID: request.transactionID
            ).encoded(
                messageIntegrityKey: key,
                includeFingerprint: true
            )
        }

        let client = TURNChannelBindClient(transport: transport)
        let result = try client.channelBind(
            channelNumber: 0x4001,
            peerAddress: peerAddress,
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            password: "relay-password",
            transactionID: transactionID,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(result.response.type, .channelBindSuccessResponse)
    }

    func testRejectsMismatchedChannelBindResponseTransactionID() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 25, count: 12))
        let wrongTransactionID = try STUNTransactionID(bytes: Array(repeating: 26, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { _ in
            try STUNMessage(
                type: .channelBindSuccessResponse,
                transactionID: wrongTransactionID
            ).encoded()
        }
        let client = TURNChannelBindClient(transport: transport)

        XCTAssertThrowsError(
            try client.channelBind(
                channelNumber: 0x4002,
                peerAddress: STUNMappedAddress(address: "203.0.113.15", port: 5_006),
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNChannelBindError, .transactionMismatch)
        }
    }

    func testMapsChannelBindErrorResponseCode() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 27, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            return try STUNMessage(
                type: .channelBindErrorResponse,
                transactionID: request.transactionID,
                attributes: [.errorCode(403, reason: "Forbidden")]
            ).encoded()
        }
        let client = TURNChannelBindClient(transport: transport)

        XCTAssertThrowsError(
            try client.channelBind(
                channelNumber: 0x4003,
                peerAddress: STUNMappedAddress(address: "203.0.113.16", port: 5_007),
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNChannelBindError, .channelBindFailed(403))
        }
    }

    func testRejectsInvalidChannelBindResponseMessageIntegrity() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 28, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            return try STUNMessage(
                type: .channelBindSuccessResponse,
                transactionID: request.transactionID
            ).encoded(
                messageIntegrityKey: TURNLongTermCredential.messageIntegrityKey(
                    username: "relay-user",
                    realm: "turn.example.test",
                    password: "wrong-password"
                )
            )
        }
        let client = TURNChannelBindClient(transport: transport)

        XCTAssertThrowsError(
            try client.channelBind(
                channelNumber: 0x4004,
                peerAddress: STUNMappedAddress(address: "203.0.113.17", port: 5_008),
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNChannelBindError, .invalidMessageIntegrity)
        }
    }

    func testRejectsInvalidChannelBindResponseFingerprint() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 29, count: 12))
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)
            var response = try STUNMessage(
                type: .channelBindSuccessResponse,
                transactionID: request.transactionID
            ).encoded(includeFingerprint: true)
            response[response.count - 1] ^= 0x01
            return response
        }
        let client = TURNChannelBindClient(transport: transport)

        XCTAssertThrowsError(
            try client.channelBind(
                channelNumber: 0x4005,
                peerAddress: STUNMappedAddress(address: "203.0.113.18", port: 5_009),
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password",
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(error as? TURNChannelBindError, .invalidFingerprint)
        }
    }

    func testChannelBindRetriesOnceOnStaleNonceWithNewNonce() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 30, count: 12))
        let retryTransactionID = try STUNTransactionID(bytes: Array(repeating: 31, count: 12))
        let peerAddress = STUNMappedAddress(address: "203.0.113.19", port: 5_010)
        let recorder = TURNRequestRecorder()
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: "relay-user",
            realm: "turn.example.test",
            password: "relay-password"
        )
        let transport = FakeTURNSTUNDatagramTransport { requestData in
            let attempt = recorder.nextAttempt()
            let request = try STUNMessage(decoding: requestData)

            XCTAssertEqual(request.type, .channelBindRequest)
            XCTAssertEqual(try request.firstAttribute(.realm)?.stringValue, "turn.example.test")
            XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
            XCTAssertTrue(try request.validatesFingerprint())

            if attempt == 1 {
                XCTAssertEqual(request.transactionID, transactionID)
                XCTAssertEqual(try request.firstAttribute(.nonce)?.stringValue, "nonce-1")

                return try STUNMessage(
                    type: .channelBindErrorResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        .errorCode(438, reason: "Stale Nonce"),
                        .nonce("nonce-2"),
                    ]
                ).encoded(
                    messageIntegrityKey: key,
                    includeFingerprint: true
                )
            }

            XCTAssertEqual(request.transactionID, retryTransactionID)
            XCTAssertEqual(try request.firstAttribute(.nonce)?.stringValue, "nonce-2")

            return try STUNMessage(
                type: .channelBindSuccessResponse,
                transactionID: request.transactionID
            ).encoded(
                messageIntegrityKey: key,
                includeFingerprint: true
            )
        }

        let client = TURNChannelBindClient(transport: transport)
        let result = try client.channelBind(
            channelNumber: 0x4006,
            peerAddress: peerAddress,
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            password: "relay-password",
            transactionID: transactionID,
            staleNonceRetryTransactionID: retryTransactionID,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(result.response.type, .channelBindSuccessResponse)
        XCTAssertEqual(recorder.attemptCount, 2)
    }

    func testRejectsCreatePermissionWithoutPeerAddress() throws {
        XCTAssertThrowsError(
            try TURNCreatePermissionRequestFactory.makeCreatePermissionRequest(
                peerAddresses: [],
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1"
            )
        ) { error in
            XCTAssertEqual(error as? STUNError, .missingAttribute(STUNAttributeType.xorPeerAddress.rawValue))
        }
    }

    func testRejectsChannelBindRequestOutsideTURNChannelRange() throws {
        let peerAddress = STUNMappedAddress(address: "203.0.113.13", port: 5_004)

        XCTAssertThrowsError(
            try TURNChannelBindRequestFactory.makeChannelBindRequest(
                channelNumber: 0x3FFF,
                peerAddress: peerAddress,
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1"
            )
        ) { error in
            XCTAssertEqual(error as? STUNError, .invalidChannelNumber(0x3FFF))
        }

        XCTAssertThrowsError(
            try TURNChannelBindRequestFactory.makeChannelBindRequest(
                channelNumber: 0x8000,
                peerAddress: peerAddress,
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1"
            )
        ) { error in
            XCTAssertEqual(error as? STUNError, .invalidChannelNumber(0x8000))
        }
    }

    func testRejectsChannelNumberAttributeWithNonZeroReservedBits() throws {
        let attribute = STUNAttribute(type: .channelNumber, value: Data([0x40, 0x00, 0x00, 0x01]))

        XCTAssertNil(attribute.channelNumberValue)
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
