import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class TURNRelaySessionTests: XCTestCase {
    func testParsesTURNRelaySessionEndpointsFromICEServer() {
        let endpoints = TURNServerEndpoint.endpoints(
            from: [
                ICEServer(
                    urls: [
                        "stun:stun.example.test:3478",
                        "turn:relay.example.test:3478?transport=udp",
                        "turn:relay-tcp.example.test:3478?transport=tcp",
                        "turns:relay-tls.example.test",
                    ],
                    username: "relay-user",
                    credential: "relay-password"
                ),
            ]
        )

        XCTAssertEqual(endpoints, [
            TURNServerEndpoint(
                host: "relay.example.test",
                port: 3_478,
                transport: .udp,
                isSecure: false,
                username: "relay-user",
                credential: "relay-password"
            ),
            TURNServerEndpoint(
                host: "relay-tcp.example.test",
                port: 3_478,
                transport: .tcp,
                isSecure: false,
                username: "relay-user",
                credential: "relay-password"
            ),
            TURNServerEndpoint(
                host: "relay-tls.example.test",
                port: 5_349,
                transport: .tcp,
                isSecure: true,
                username: "relay-user",
                credential: "relay-password"
            ),
        ])
    }

    func testBuildsTURNRelaySessionConfigurationForSupportedUDPEndpoint() throws {
        let endpoint = TURNServerEndpoint(
            host: "relay.example.test",
            port: 3_478,
            transport: .udp,
            isSecure: false,
            username: "relay-user",
            credential: "relay-password"
        )

        let configuration = try TURNRelaySessionConfiguration(
            endpoint: endpoint,
            realm: "turn.example.test",
            nonce: "nonce-1"
        )

        XCTAssertEqual(configuration.endpoint, endpoint)
        XCTAssertEqual(configuration.relayedTransport, .udp)
        XCTAssertEqual(
            configuration.credentials,
            TURNRelaySessionCredentials(
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password"
            )
        )
    }

    func testRejectsTURNRelaySessionConfigurationWithoutEndpointCredentials() {
        let endpoint = TURNServerEndpoint(
            host: "relay.example.test",
            port: 3_478,
            transport: .udp,
            isSecure: false,
            username: "relay-user",
            credential: nil
        )

        XCTAssertThrowsError(try TURNRelaySessionConfiguration(
            endpoint: endpoint,
            realm: "turn.example.test",
            nonce: "nonce-1"
        )) { error in
            XCTAssertEqual(
                error as? TURNRelaySessionConfigurationError,
                .missingCredentials(host: "relay.example.test", port: 3_478)
            )
        }
    }

    func testRejectsTURNRelaySessionConfigurationWithUnsupportedTransportIntent() {
        let endpoint = TURNServerEndpoint(
            host: "relay-tcp.example.test",
            port: 3_478,
            transport: .tcp,
            isSecure: false,
            username: "relay-user",
            credential: "relay-password"
        )

        XCTAssertThrowsError(try TURNRelaySessionConfiguration(
            endpoint: endpoint,
            realm: "turn.example.test",
            nonce: "nonce-1"
        )) { error in
            XCTAssertEqual(
                error as? TURNRelaySessionConfigurationError,
                .unsupportedTransportIntent(
                    host: "relay-tcp.example.test",
                    port: 3_478,
                    transport: .tcp,
                    isSecure: false
                )
            )
        }
    }

    func testFirstSupportedTURNRelaySessionConfigurationSelectsFirstUDPEndpointWithCredentials() throws {
        let configuration = try TURNRelaySessionConfiguration.firstSupportedUDP(
            from: [
                ICEServer(
                    urls: ["turn:first-missing.example.test:3478?transport=udp"],
                    username: "relay-user",
                    credential: nil
                ),
                ICEServer(
                    urls: ["turn:first-tcp.example.test:3478?transport=tcp"],
                    username: "relay-user",
                    credential: "relay-password"
                ),
                ICEServer(
                    urls: [
                        "turn:first-supported.example.test:3478?transport=udp",
                        "turn:second-supported.example.test:3478?transport=udp",
                    ],
                    username: "relay-user",
                    credential: "relay-password"
                ),
            ],
            realm: "turn.example.test",
            nonce: "nonce-1"
        )

        XCTAssertEqual(configuration.endpoint.host, "first-supported.example.test")
        XCTAssertEqual(configuration.endpoint.port, 3_478)
        XCTAssertEqual(configuration.relayedTransport, .udp)
        XCTAssertEqual(configuration.credentials.username, "relay-user")
        XCTAssertEqual(configuration.credentials.password, "relay-password")
    }

    func testFirstSupportedTURNRelaySessionConfigurationFailsWhenNoUDPEndpointHasCredentials() {
        XCTAssertThrowsError(try TURNRelaySessionConfiguration.firstSupportedUDP(
            from: [
                ICEServer(
                    urls: ["turn:tcp.example.test:3478?transport=tcp"],
                    username: "relay-user",
                    credential: "relay-password"
                ),
                ICEServer(
                    urls: ["turn:missing.example.test:3478?transport=udp"],
                    username: "relay-user",
                    credential: nil
                ),
                ICEServer(
                    urls: ["turns:tls.example.test"],
                    username: "relay-user",
                    credential: "relay-password"
                ),
            ],
            realm: "turn.example.test",
            nonce: "nonce-1"
        )) { error in
            XCTAssertEqual(
                error as? TURNRelaySessionConfigurationError,
                .noSupportedUDPEndpointWithCredentials
            )
        }
    }

    func testSetupPlanCarriesConfigurationPeerChannelAndLifetimeDetails() throws {
        let endpoint = TURNServerEndpoint(
            host: "relay.example.test",
            port: 3_478,
            transport: .udp,
            isSecure: false,
            username: "relay-user",
            credential: "relay-password"
        )
        let configuration = try TURNRelaySessionConfiguration(
            endpoint: endpoint,
            realm: "turn.example.test",
            nonce: "nonce-1"
        )
        let peerAddress = STUNMappedAddress(address: "203.0.113.44", port: 5_000)
        let transactionIDs = try setupTransactionIDs()

        let plan = configuration.makeSetupPlan(
            peerAddress: peerAddress,
            channelNumber: 0x4007,
            transactionIDs: transactionIDs,
            permissionID: "peer-1",
            allocationLifetimeSeconds: 180,
            permissionLifetimeSeconds: 120,
            foundation: "relay-foundation",
            localPreference: 250
        )
        let session = plan.makeSession(stunTransport: EmptyTURNRelaySessionSTUNTransport())

        XCTAssertEqual(plan.configuration, configuration)
        XCTAssertEqual(plan.endpoint, endpoint)
        XCTAssertEqual(
            plan.credentials,
            TURNRelaySessionCredentials(
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password"
            )
        )
        XCTAssertEqual(plan.relayedTransport, .udp)
        XCTAssertEqual(plan.peerAddress, peerAddress)
        XCTAssertEqual(plan.channelNumber, 0x4007)
        XCTAssertEqual(plan.transactionIDs, transactionIDs)
        XCTAssertEqual(plan.permissionID, "peer-1")
        XCTAssertEqual(plan.allocationLifetimeSeconds, 180)
        XCTAssertEqual(plan.permissionLifetimeSeconds, 120)
        XCTAssertEqual(plan.foundation, "relay-foundation")
        XCTAssertEqual(plan.localPreference, 250)
        XCTAssertEqual(session.credentials, plan.credentials)
        XCTAssertEqual(session.turnEndpoint, endpoint)
        XCTAssertEqual(session.relayedTransport, .udp)
    }

    func testSetupPlanUsesDeterministicDefaultPermissionID() throws {
        let configuration = try TURNRelaySessionConfiguration(
            endpoint: TURNServerEndpoint(
                host: "relay.example.test",
                port: 3_478,
                transport: .udp,
                isSecure: false,
                username: "relay-user",
                credential: "relay-password"
            ),
            realm: "turn.example.test",
            nonce: "nonce-1"
        )
        let peerAddress = STUNMappedAddress(address: "203.0.113.45", port: 5_001)

        let plan = configuration.makeSetupPlan(
            peerAddress: peerAddress,
            channelNumber: 0x4008,
            transactionIDs: try setupTransactionIDs()
        )

        XCTAssertEqual(plan.permissionID, "203.0.113.45:5001")
        XCTAssertNil(plan.allocationLifetimeSeconds)
        XCTAssertEqual(
            plan.permissionLifetimeSeconds,
            TURNMaintenancePolicy.defaultPermissionLifetimeSeconds
        )
        XCTAssertNil(plan.foundation)
        XCTAssertEqual(
            plan.localPreference,
            TURNRelayCandidateFactory.defaultLocalPreference
        )
    }

    func testSetupPlanExecutesThroughScriptedTransportAndPreservesMetadata() async throws {
        let endpoint = TURNServerEndpoint(
            host: "relay.example.test",
            port: 3_478,
            transport: .udp,
            isSecure: false,
            username: "relay-user",
            credential: "relay-password"
        )
        let configuration = try TURNRelaySessionConfiguration(
            endpoint: endpoint,
            realm: "turn.example.test",
            nonce: "nonce-1"
        )
        let credentials = configuration.credentials
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: credentials.username,
            realm: credentials.realm,
            password: credentials.password
        )
        let peerAddress = STUNMappedAddress(address: "203.0.113.46", port: 5_002)
        let relayedAddress = STUNMappedAddress(address: "192.0.2.79", port: 49_154)
        let transactionIDs = try setupTransactionIDs()
        let plan = configuration.makeSetupPlan(
            peerAddress: peerAddress,
            channelNumber: 0x4009,
            transactionIDs: transactionIDs,
            permissionID: "peer-plan",
            allocationLifetimeSeconds: 180,
            permissionLifetimeSeconds: 120,
            foundation: "relay-foundation",
            localPreference: 250
        )
        let stunTransport = ScriptedTURNRelaySessionSTUNTransport { attempt, request in
            switch attempt {
            case 1:
                XCTAssertEqual(request.type, .allocateRequest)
                XCTAssertEqual(request.transactionID, transactionIDs.allocation)
                XCTAssertNil(request.firstAttribute(.messageIntegrity))

                return try STUNMessage(
                    type: .allocateErrorResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        .errorCode(401, reason: "Unauthorized"),
                        .realm(credentials.realm),
                        .nonce(credentials.nonce),
                    ]
                ).encoded(includeFingerprint: true)
            case 2:
                XCTAssertEqual(request.type, .allocateRequest)
                XCTAssertEqual(request.transactionID, transactionIDs.authenticatedAllocation)
                XCTAssertEqual(request.firstAttribute(.requestedTransport)?.requestedTransportProtocol, .udp)
                XCTAssertEqual(request.firstAttribute(.lifetime)?.uint32Value, 180)
                XCTAssertEqual(try request.firstAttribute(.username)?.stringValue, credentials.username)
                XCTAssertEqual(try request.firstAttribute(.realm)?.stringValue, credentials.realm)
                XCTAssertEqual(try request.firstAttribute(.nonce)?.stringValue, credentials.nonce)
                XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
                XCTAssertTrue(try request.validatesFingerprint())

                return try STUNMessage(
                    type: .allocateSuccessResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        try .xorRelayedAddressIPv4(
                            address: relayedAddress.address,
                            port: relayedAddress.port,
                            transactionID: request.transactionID
                        ),
                        .lifetime(seconds: 180),
                    ]
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            case 3:
                XCTAssertEqual(request.type, .createPermissionRequest)
                XCTAssertEqual(request.transactionID, transactionIDs.createPermission)
                XCTAssertEqual(
                    try request.firstAttribute(.xorPeerAddress)?.xorPeerAddressValue,
                    peerAddress
                )
                XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
                XCTAssertTrue(try request.validatesFingerprint())

                return try STUNMessage(
                    type: .createPermissionSuccessResponse,
                    transactionID: request.transactionID
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            case 4:
                XCTAssertEqual(request.type, .channelBindRequest)
                XCTAssertEqual(request.transactionID, transactionIDs.channelBind)
                XCTAssertEqual(request.firstAttribute(.channelNumber)?.channelNumberValue, 0x4009)
                XCTAssertEqual(
                    try request.firstAttribute(.xorPeerAddress)?.xorPeerAddressValue,
                    peerAddress
                )
                XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
                XCTAssertTrue(try request.validatesFingerprint())

                return try STUNMessage(
                    type: .channelBindSuccessResponse,
                    transactionID: request.transactionID
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            default:
                XCTFail("Unexpected TURN request attempt \(attempt).")
                return Data()
            }
        }
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )

        let execution = try plan.executeSetup(
            stunTransport: stunTransport,
            datagramTransport: FakeTURNRelaySessionMediaDatagramTransport(),
            at: 100,
            policy: policy,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(execution.session.credentials, credentials)
        XCTAssertEqual(execution.session.turnEndpoint, endpoint)
        XCTAssertEqual(execution.session.relayedTransport, .udp)
        XCTAssertEqual(execution.result.allocation.relayedAddress, relayedAddress)
        XCTAssertEqual(execution.result.metadata.turnEndpoint, endpoint)
        XCTAssertEqual(execution.result.metadata.relayedTransport, .udp)
        XCTAssertEqual(execution.result.metadata.peerAddress, peerAddress)
        XCTAssertEqual(execution.result.metadata.channelNumber, 0x4009)
        XCTAssertEqual(execution.result.metadata.permissionID, "peer-plan")
        XCTAssertEqual(execution.result.metadata.nextMaintenanceDeadline, 200)
        XCTAssertEqual(execution.result.candidatePlan.candidate.foundation, "relay-foundation")
        XCTAssertEqual(execution.result.candidatePlan.candidate.localPreference, 250)
        XCTAssertEqual(stunTransport.attemptCount, 4)
    }

    func testSetupAllocatesCreatesPermissionBindsChannelAndReturnsRelayPlan() async throws {
        let credentials = TURNRelaySessionCredentials(
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            password: "relay-password"
        )
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: credentials.username,
            realm: credentials.realm,
            password: credentials.password
        )
        let peerAddress = STUNMappedAddress(address: "203.0.113.44", port: 5_000)
        let relayedAddress = STUNMappedAddress(address: "192.0.2.77", port: 49_152)
        let transactionIDs = try setupTransactionIDs()
        let stunTransport = ScriptedTURNRelaySessionSTUNTransport { attempt, request in
            switch attempt {
            case 1:
                XCTAssertEqual(request.type, .allocateRequest)
                XCTAssertEqual(request.transactionID, transactionIDs.allocation)
                XCTAssertNil(request.firstAttribute(.messageIntegrity))

                return try STUNMessage(
                    type: .allocateErrorResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        .errorCode(401, reason: "Unauthorized"),
                        .realm(credentials.realm),
                        .nonce(credentials.nonce),
                    ]
                ).encoded(includeFingerprint: true)
            case 2:
                XCTAssertEqual(request.type, .allocateRequest)
                XCTAssertEqual(request.transactionID, transactionIDs.authenticatedAllocation)
                XCTAssertEqual(request.firstAttribute(.lifetime)?.uint32Value, 180)
                XCTAssertEqual(try request.firstAttribute(.username)?.stringValue, credentials.username)
                XCTAssertEqual(try request.firstAttribute(.realm)?.stringValue, credentials.realm)
                XCTAssertEqual(try request.firstAttribute(.nonce)?.stringValue, credentials.nonce)
                XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
                XCTAssertTrue(try request.validatesFingerprint())

                return try STUNMessage(
                    type: .allocateSuccessResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        try .xorRelayedAddressIPv4(
                            address: relayedAddress.address,
                            port: relayedAddress.port,
                            transactionID: request.transactionID
                        ),
                        .lifetime(seconds: 180),
                    ]
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            case 3:
                XCTAssertEqual(request.type, .createPermissionRequest)
                XCTAssertEqual(request.transactionID, transactionIDs.createPermission)
                XCTAssertEqual(
                    try request.firstAttribute(.xorPeerAddress)?.xorPeerAddressValue,
                    peerAddress
                )
                XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
                XCTAssertTrue(try request.validatesFingerprint())

                return try STUNMessage(
                    type: .createPermissionSuccessResponse,
                    transactionID: request.transactionID
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            case 4:
                XCTAssertEqual(request.type, .channelBindRequest)
                XCTAssertEqual(request.transactionID, transactionIDs.channelBind)
                XCTAssertEqual(request.firstAttribute(.channelNumber)?.channelNumberValue, 0x4007)
                XCTAssertEqual(
                    try request.firstAttribute(.xorPeerAddress)?.xorPeerAddressValue,
                    peerAddress
                )
                XCTAssertTrue(try request.validatesMessageIntegrity(key: key))
                XCTAssertTrue(try request.validatesFingerprint())

                return try STUNMessage(
                    type: .channelBindSuccessResponse,
                    transactionID: request.transactionID
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            default:
                XCTFail("Unexpected TURN request attempt \(attempt).")
                return Data()
            }
        }
        let mediaTransport = FakeTURNRelaySessionMediaDatagramTransport()
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )
        var session = TURNRelaySession(
            stunTransport: stunTransport,
            credentials: credentials,
            policy: policy
        )

        let result = try session.setupRelay(
            peerAddress: peerAddress,
            channelNumber: 0x4007,
            datagramTransport: mediaTransport,
            at: 100,
            permissionID: "peer-1",
            allocationLifetimeSeconds: 180,
            permissionLifetimeSeconds: 120,
            foundation: "relay-foundation",
            localPreference: 250,
            transactionIDs: transactionIDs,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(result.allocation.relayedAddress, relayedAddress)
        XCTAssertEqual(result.createPermission.response.type, .createPermissionSuccessResponse)
        XCTAssertEqual(result.channelBind.response.type, .channelBindSuccessResponse)
        XCTAssertEqual(result.candidatePlan.relayedAddress, relayedAddress)
        XCTAssertEqual(result.candidatePlan.channelBinding.peerAddress, peerAddress)
        XCTAssertEqual(result.candidatePlan.candidate.foundation, "relay-foundation")
        XCTAssertEqual(result.candidatePlan.candidate.localPreference, 250)
        XCTAssertEqual(result.metadata.relayedAddress, relayedAddress)
        XCTAssertEqual(result.metadata.peerAddress, peerAddress)
        XCTAssertEqual(result.metadata.channelNumber, 0x4007)
        XCTAssertEqual(result.metadata.permissionID, "peer-1")
        XCTAssertEqual(result.metadata.nextMaintenanceDeadline, 200)
        XCTAssertEqual(session.transportMetadata(after: 100), result.metadata)
        XCTAssertEqual(session.nextMaintenanceDeadline(after: 100), 200)
        XCTAssertEqual(stunTransport.attemptCount, 4)

        try await result.relayTransport.send(
            Data([0xDE, 0xAD]),
            to: result.candidatePlan.channelBinding
        )

        let sentDatagrams = await mediaTransport.sentDatagramsSnapshot()
        XCTAssertEqual(
            sentDatagrams,
            [
                try TURNChannelDataFrame(
                    channelNumber: 0x4007,
                    payload: Data([0xDE, 0xAD])
                ).encoded(),
            ]
        )
    }

    func testExecuteDueMaintenanceUsesTURNClientsAndAdvancesDeadlines() async throws {
        let credentials = TURNRelaySessionCredentials(
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            password: "relay-password"
        )
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: credentials.username,
            realm: credentials.realm,
            password: credentials.password
        )
        let peerAddress = STUNMappedAddress(address: "203.0.113.45", port: 5_001)
        let setupIDs = try setupTransactionIDs()
        let maintenanceIDs = try TURNRelaySessionMaintenanceTransactionIDs(
            allocationRefresh: transactionID(20),
            staleNonceAllocationRefreshRetry: transactionID(21),
            createPermissionRefresh: transactionID(22),
            staleNonceCreatePermissionRefreshRetry: transactionID(23)
        )
        let stunTransport = ScriptedTURNRelaySessionSTUNTransport { attempt, request in
            switch attempt {
            case 1:
                return try STUNMessage(
                    type: .allocateErrorResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        .errorCode(401, reason: "Unauthorized"),
                        .realm(credentials.realm),
                        .nonce(credentials.nonce),
                    ]
                ).encoded(includeFingerprint: true)
            case 2:
                return try STUNMessage(
                    type: .allocateSuccessResponse,
                    transactionID: request.transactionID,
                    attributes: [
                        try .xorRelayedAddressIPv4(
                            address: "192.0.2.78",
                            port: 49_153,
                            transactionID: request.transactionID
                        ),
                        .lifetime(seconds: 100),
                    ]
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            case 3:
                XCTAssertEqual(request.type, .createPermissionRequest)
                XCTAssertEqual(request.transactionID, setupIDs.createPermission)
                return try STUNMessage(
                    type: .createPermissionSuccessResponse,
                    transactionID: request.transactionID
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            case 4:
                XCTAssertEqual(request.type, .channelBindRequest)
                XCTAssertEqual(request.transactionID, setupIDs.channelBind)
                return try STUNMessage(
                    type: .channelBindSuccessResponse,
                    transactionID: request.transactionID
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            case 5:
                XCTAssertEqual(request.type, .createPermissionRequest)
                XCTAssertEqual(request.transactionID, maintenanceIDs.createPermissionRefresh)
                XCTAssertEqual(
                    try request.firstAttribute(.xorPeerAddress)?.xorPeerAddressValue,
                    peerAddress
                )
                XCTAssertTrue(try request.validatesMessageIntegrity(key: key))

                return try STUNMessage(
                    type: .createPermissionSuccessResponse,
                    transactionID: request.transactionID
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            case 6:
                XCTAssertEqual(request.type, .refreshRequest)
                XCTAssertEqual(request.transactionID, maintenanceIDs.allocationRefresh)
                XCTAssertEqual(request.firstAttribute(.lifetime)?.uint32Value, 100)
                XCTAssertTrue(try request.validatesMessageIntegrity(key: key))

                return try STUNMessage(
                    type: .refreshSuccessResponse,
                    transactionID: request.transactionID,
                    attributes: [.lifetime(seconds: 120)]
                ).encoded(messageIntegrityKey: key, includeFingerprint: true)
            default:
                XCTFail("Unexpected TURN request attempt \(attempt).")
                return Data()
            }
        }
        let policy = TURNMaintenancePolicy(
            allocationRefreshSafetyMarginSeconds: 10,
            permissionRefreshSafetyMarginSeconds: 20
        )
        var session = TURNRelaySession(
            stunTransport: stunTransport,
            credentials: credentials,
            policy: policy
        )
        _ = try session.setupRelay(
            peerAddress: peerAddress,
            channelNumber: 0x4008,
            datagramTransport: FakeTURNRelaySessionMediaDatagramTransport(),
            at: 100,
            permissionID: "peer-2",
            allocationLifetimeSeconds: 100,
            permissionLifetimeSeconds: 100,
            transactionIDs: setupIDs,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        let results = await session.executeDueMaintenance(
            at: 190,
            transactionIDs: maintenanceIDs,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(results.map(\.action.target), [.permission("peer-2"), .allocation])
        XCTAssertEqual(results.compactMap(\.successLifetimeSeconds), [100, 120])
        XCTAssertEqual(session.dueMaintenanceActions(at: 269), [])
        XCTAssertEqual(session.nextMaintenanceDeadline(after: 269), 270)
        XCTAssertEqual(session.dueMaintenanceActions(at: 270).map(\.target), [.permission("peer-2")])
        XCTAssertEqual(session.dueMaintenanceActions(at: 300).map(\.target), [.permission("peer-2"), .allocation])
        XCTAssertEqual(stunTransport.attemptCount, 6)
    }

    func testCustomMaintenanceExecutorCanDriveSessionScheduler() async throws {
        let credentials = TURNRelaySessionCredentials(
            username: "relay-user",
            realm: "turn.example.test",
            nonce: "nonce-1",
            password: "relay-password"
        )
        var scheduler = TURNMaintenanceScheduler(
            allocation: TURNAllocationMaintenanceState(
                allocatedAt: 100,
                lifetimeSeconds: 100,
                policy: TURNMaintenancePolicy(
                    allocationRefreshSafetyMarginSeconds: 10,
                    permissionRefreshSafetyMarginSeconds: 20
                )
            )
        )
        scheduler.recordPermissionRefreshSuccess(
            id: "peer-3",
            at: 100,
            lifetimeSeconds: 100,
            policy: TURNMaintenancePolicy(
                allocationRefreshSafetyMarginSeconds: 10,
                permissionRefreshSafetyMarginSeconds: 20
            )
        )
        var session = TURNRelaySession(
            allocationClient: TURNAllocationClient(transport: EmptyTURNRelaySessionSTUNTransport()),
            refreshClient: TURNRefreshClient(transport: EmptyTURNRelaySessionSTUNTransport()),
            createPermissionClient: TURNCreatePermissionClient(transport: EmptyTURNRelaySessionSTUNTransport()),
            channelBindClient: TURNChannelBindClient(transport: EmptyTURNRelaySessionSTUNTransport()),
            credentials: credentials,
            policy: TURNMaintenancePolicy(
                allocationRefreshSafetyMarginSeconds: 10,
                permissionRefreshSafetyMarginSeconds: 20
            ),
            scheduler: scheduler
        )
        let executor = TURNMaintenanceExecutor(
            policy: session.policy,
            refreshAllocation: { 120 },
            refreshPermission: { id in
                XCTAssertEqual(id, "peer-3")
                return 100
            }
        )

        let results = await session.executeDueMaintenance(executor: executor, at: 190)

        XCTAssertEqual(results.map(\.action.target), [.permission("peer-3"), .allocation])
        XCTAssertEqual(results.compactMap(\.successLifetimeSeconds), [100, 120])
        XCTAssertEqual(session.nextMaintenanceDeadline(after: 269), 270)
    }

    private func setupTransactionIDs() throws -> TURNRelaySessionTransactionIDs {
        try TURNRelaySessionTransactionIDs(
            allocation: transactionID(1),
            authenticatedAllocation: transactionID(2),
            staleNonceAllocationRetry: transactionID(3),
            createPermission: transactionID(4),
            staleNonceCreatePermissionRetry: transactionID(5),
            channelBind: transactionID(6),
            staleNonceChannelBindRetry: transactionID(7)
        )
    }

    private func transactionID(_ byte: UInt8) throws -> STUNTransactionID {
        try STUNTransactionID(bytes: Array(repeating: byte, count: STUNTransactionID.byteCount))
    }
}

private final class ScriptedTURNRelaySessionSTUNTransport: STUNDatagramTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private let handler: (Int, STUNMessage) throws -> Data

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    init(handler: @escaping (Int, STUNMessage) throws -> Data) {
        self.handler = handler
    }

    func send(_ data: Data) throws -> Data {
        let attempt = nextAttempt()
        return try handler(attempt, try STUNMessage(decoding: data))
    }

    private func nextAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        return attempts
    }
}

private struct EmptyTURNRelaySessionSTUNTransport: STUNDatagramTransport {
    func send(_ data: Data) throws -> Data {
        data
    }
}

private actor FakeTURNRelaySessionMediaDatagramTransport: MediaDatagramTransport {
    private var sentDatagrams: [Data] = []
    private var incomingDatagrams: [Data] = []

    func sentDatagramsSnapshot() -> [Data] {
        sentDatagrams
    }

    func send(_ datagram: Data) async throws {
        sentDatagrams.append(datagram)
    }

    func receive() async throws -> Data {
        guard !incomingDatagrams.isEmpty else {
            throw FakeTURNRelaySessionMediaDatagramTransportError.empty
        }

        return incomingDatagrams.removeFirst()
    }
}

private enum FakeTURNRelaySessionMediaDatagramTransportError: Error {
    case empty
}

private extension TURNMaintenanceExecutionResult {
    var successLifetimeSeconds: UInt32? {
        guard case let .success(lifetimeSeconds) = outcome else {
            return nil
        }

        return lifetimeSeconds
    }
}
