import Foundation

package struct TURNRelaySessionCredentials: Equatable, Sendable {
    package var username: String
    package var realm: String
    package var nonce: String
    package var password: String

    package init(
        username: String,
        realm: String,
        nonce: String,
        password: String
    ) {
        self.username = username
        self.realm = realm
        self.nonce = nonce
        self.password = password
    }

    package init(
        endpoint: TURNServerEndpoint,
        realm: String,
        nonce: String
    ) throws {
        let endpointCredentials = try TURNRelaySessionEndpointCredentials(endpoint: endpoint)
        self.init(
            username: endpointCredentials.username,
            realm: realm,
            nonce: nonce,
            password: endpointCredentials.password
        )
    }
}

package struct TURNRelaySessionEndpointCredentials: Equatable, Sendable {
    package var username: String
    package var password: String

    package init(endpoint: TURNServerEndpoint) throws {
        guard let username = endpoint.username, username.isEmpty == false,
              let password = endpoint.credential, password.isEmpty == false
        else {
            throw TURNRelaySessionConfigurationError.missingCredentials(
                host: endpoint.host,
                port: endpoint.port
            )
        }

        self.username = username
        self.password = password
    }
}

package struct TURNRelaySessionConfiguration: Equatable, Sendable {
    package var endpoint: TURNServerEndpoint
    package var credentials: TURNRelaySessionCredentials
    package var relayedTransport: TURNRequestedTransportProtocol

    package init(
        endpoint: TURNServerEndpoint,
        realm: String,
        nonce: String
    ) throws {
        guard endpoint.transport == .udp, endpoint.isSecure == false else {
            throw TURNRelaySessionConfigurationError.unsupportedTransportIntent(
                host: endpoint.host,
                port: endpoint.port,
                transport: endpoint.transport,
                isSecure: endpoint.isSecure
            )
        }

        self.endpoint = endpoint
        self.credentials = try TURNRelaySessionCredentials(
            endpoint: endpoint,
            realm: realm,
            nonce: nonce
        )
        self.relayedTransport = .udp
    }

    package static func firstSupportedUDP(
        from endpoints: [TURNServerEndpoint],
        realm: String,
        nonce: String
    ) throws -> TURNRelaySessionConfiguration {
        for endpoint in endpoints where endpoint.transport == .udp && endpoint.isSecure == false {
            guard let username = endpoint.username, username.isEmpty == false,
                  let credential = endpoint.credential, credential.isEmpty == false
            else {
                continue
            }

            return try TURNRelaySessionConfiguration(
                endpoint: endpoint,
                realm: realm,
                nonce: nonce
            )
        }

        throw TURNRelaySessionConfigurationError.noSupportedUDPEndpointWithCredentials
    }

    package static func firstSupportedUDP(
        from iceServers: [ICEServer],
        realm: String,
        nonce: String
    ) throws -> TURNRelaySessionConfiguration {
        try firstSupportedUDP(
            from: TURNServerEndpoint.endpoints(from: iceServers),
            realm: realm,
            nonce: nonce
        )
    }

    package func makeSession(
        stunTransport: any STUNDatagramTransport,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0
    ) -> TURNRelaySession {
        TURNRelaySession(
            stunTransport: stunTransport,
            configuration: self,
            policy: policy,
            jitterSeconds: jitterSeconds
        )
    }

    package func makeSetupPlan(
        peerAddress: STUNMappedAddress,
        channelNumber: UInt16,
        transactionIDs: TURNRelaySessionTransactionIDs,
        permissionID: TURNMaintenanceScheduler.PermissionID? = nil,
        allocationLifetimeSeconds: UInt32? = nil,
        permissionLifetimeSeconds: UInt32 = TURNMaintenancePolicy.defaultPermissionLifetimeSeconds,
        foundation: String? = nil,
        localPreference: UInt16 = TURNRelayCandidateFactory.defaultLocalPreference
    ) -> TURNRelaySessionSetupPlan {
        TURNRelaySessionSetupPlan(
            configuration: self,
            peerAddress: peerAddress,
            channelNumber: channelNumber,
            transactionIDs: transactionIDs,
            permissionID: permissionID,
            allocationLifetimeSeconds: allocationLifetimeSeconds,
            permissionLifetimeSeconds: permissionLifetimeSeconds,
            foundation: foundation,
            localPreference: localPreference
        )
    }
}

package enum TURNRelaySessionConfigurationError: Error, Equatable, Sendable {
    case missingCredentials(host: String, port: UInt16)
    case unsupportedTransportIntent(
        host: String,
        port: UInt16,
        transport: ICETransportProtocol,
        isSecure: Bool
    )
    case noSupportedUDPEndpointWithCredentials
}

package struct TURNRelaySessionTransactionIDs: Equatable, Sendable {
    package var allocation: STUNTransactionID
    package var authenticatedAllocation: STUNTransactionID
    package var staleNonceAllocationRetry: STUNTransactionID
    package var createPermission: STUNTransactionID
    package var staleNonceCreatePermissionRetry: STUNTransactionID
    package var channelBind: STUNTransactionID
    package var staleNonceChannelBindRetry: STUNTransactionID

    package init(
        allocation: STUNTransactionID = .random(),
        authenticatedAllocation: STUNTransactionID = .random(),
        staleNonceAllocationRetry: STUNTransactionID = .random(),
        createPermission: STUNTransactionID = .random(),
        staleNonceCreatePermissionRetry: STUNTransactionID = .random(),
        channelBind: STUNTransactionID = .random(),
        staleNonceChannelBindRetry: STUNTransactionID = .random()
    ) {
        self.allocation = allocation
        self.authenticatedAllocation = authenticatedAllocation
        self.staleNonceAllocationRetry = staleNonceAllocationRetry
        self.createPermission = createPermission
        self.staleNonceCreatePermissionRetry = staleNonceCreatePermissionRetry
        self.channelBind = channelBind
        self.staleNonceChannelBindRetry = staleNonceChannelBindRetry
    }
}

package struct TURNRelaySessionMaintenanceTransactionIDs: Equatable, Sendable {
    package var allocationRefresh: STUNTransactionID
    package var staleNonceAllocationRefreshRetry: STUNTransactionID
    package var createPermissionRefresh: STUNTransactionID
    package var staleNonceCreatePermissionRefreshRetry: STUNTransactionID

    package init(
        allocationRefresh: STUNTransactionID = .random(),
        staleNonceAllocationRefreshRetry: STUNTransactionID = .random(),
        createPermissionRefresh: STUNTransactionID = .random(),
        staleNonceCreatePermissionRefreshRetry: STUNTransactionID = .random()
    ) {
        self.allocationRefresh = allocationRefresh
        self.staleNonceAllocationRefreshRetry = staleNonceAllocationRefreshRetry
        self.createPermissionRefresh = createPermissionRefresh
        self.staleNonceCreatePermissionRefreshRetry = staleNonceCreatePermissionRefreshRetry
    }
}

package struct TURNRelaySessionSetupPlan: Equatable, Sendable {
    package var configuration: TURNRelaySessionConfiguration
    package var peerAddress: STUNMappedAddress
    package var channelNumber: UInt16
    package var transactionIDs: TURNRelaySessionTransactionIDs
    package var permissionID: TURNMaintenanceScheduler.PermissionID
    package var allocationLifetimeSeconds: UInt32?
    package var permissionLifetimeSeconds: UInt32
    package var foundation: String?
    package var localPreference: UInt16

    package var endpoint: TURNServerEndpoint {
        configuration.endpoint
    }

    package var credentials: TURNRelaySessionCredentials {
        configuration.credentials
    }

    package var relayedTransport: TURNRequestedTransportProtocol {
        configuration.relayedTransport
    }

    package init(
        configuration: TURNRelaySessionConfiguration,
        peerAddress: STUNMappedAddress,
        channelNumber: UInt16,
        transactionIDs: TURNRelaySessionTransactionIDs,
        permissionID: TURNMaintenanceScheduler.PermissionID? = nil,
        allocationLifetimeSeconds: UInt32? = nil,
        permissionLifetimeSeconds: UInt32 = TURNMaintenancePolicy.defaultPermissionLifetimeSeconds,
        foundation: String? = nil,
        localPreference: UInt16 = TURNRelayCandidateFactory.defaultLocalPreference
    ) {
        self.configuration = configuration
        self.peerAddress = peerAddress
        self.channelNumber = channelNumber
        self.transactionIDs = transactionIDs
        self.permissionID = permissionID ?? TURNRelaySession.permissionID(for: peerAddress)
        self.allocationLifetimeSeconds = allocationLifetimeSeconds
        self.permissionLifetimeSeconds = permissionLifetimeSeconds
        self.foundation = foundation
        self.localPreference = localPreference
    }

    package func makeSession(
        stunTransport: any STUNDatagramTransport,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0
    ) -> TURNRelaySession {
        configuration.makeSession(
            stunTransport: stunTransport,
            policy: policy,
            jitterSeconds: jitterSeconds
        )
    }

    package func executeSetup(
        stunTransport: any STUNDatagramTransport,
        datagramTransport: any MediaDatagramTransport,
        at now: TimeInterval,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0,
        includeFingerprint: Bool = true,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) throws -> TURNRelaySessionSetupExecution {
        var session = makeSession(
            stunTransport: stunTransport,
            policy: policy,
            jitterSeconds: jitterSeconds
        )
        let result = try session.setupRelay(
            plan: self,
            datagramTransport: datagramTransport,
            at: now,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )

        return TURNRelaySessionSetupExecution(session: session, result: result)
    }
}

package struct TURNRelaySessionSetupExecution: Sendable {
    package var session: TURNRelaySession
    package var result: TURNRelaySessionSetupResult

    package init(
        session: TURNRelaySession,
        result: TURNRelaySessionSetupResult
    ) {
        self.session = session
        self.result = result
    }
}

package struct TURNRelaySessionTransportMetadata: Equatable, Sendable {
    package var turnEndpoint: TURNServerEndpoint?
    package var relayedTransport: TURNRequestedTransportProtocol
    package var relayedAddress: STUNMappedAddress
    package var peerAddress: STUNMappedAddress
    package var channelNumber: UInt16
    package var permissionID: TURNMaintenanceScheduler.PermissionID
    package var candidate: ICECandidate
    package var nextMaintenanceDeadline: TimeInterval?

    package init(
        turnEndpoint: TURNServerEndpoint? = nil,
        relayedTransport: TURNRequestedTransportProtocol = .udp,
        relayedAddress: STUNMappedAddress,
        peerAddress: STUNMappedAddress,
        channelNumber: UInt16,
        permissionID: TURNMaintenanceScheduler.PermissionID,
        candidate: ICECandidate,
        nextMaintenanceDeadline: TimeInterval?
    ) {
        self.turnEndpoint = turnEndpoint
        self.relayedTransport = relayedTransport
        self.relayedAddress = relayedAddress
        self.peerAddress = peerAddress
        self.channelNumber = channelNumber
        self.permissionID = permissionID
        self.candidate = candidate
        self.nextMaintenanceDeadline = nextMaintenanceDeadline
    }
}

package struct TURNRelaySessionSetupResult: Sendable {
    package var allocation: TURNAllocationResult
    package var createPermission: TURNCreatePermissionResult
    package var channelBind: TURNChannelBindResult
    package var candidatePlan: TURNRelayCandidatePlan
    package var relayTransport: TURNRelayTransport
    package var metadata: TURNRelaySessionTransportMetadata
    package var scheduler: TURNMaintenanceScheduler

    package init(
        allocation: TURNAllocationResult,
        createPermission: TURNCreatePermissionResult,
        channelBind: TURNChannelBindResult,
        candidatePlan: TURNRelayCandidatePlan,
        relayTransport: TURNRelayTransport,
        metadata: TURNRelaySessionTransportMetadata,
        scheduler: TURNMaintenanceScheduler
    ) {
        self.allocation = allocation
        self.createPermission = createPermission
        self.channelBind = channelBind
        self.candidatePlan = candidatePlan
        self.relayTransport = relayTransport
        self.metadata = metadata
        self.scheduler = scheduler
    }
}

package enum TURNRelaySessionError: Error, Equatable, Sendable {
    case setupRequired
    case unknownPermission(String)
}

package struct TURNRelaySession: Sendable {
    package var allocationClient: TURNAllocationClient
    package var refreshClient: TURNRefreshClient
    package var createPermissionClient: TURNCreatePermissionClient
    package var channelBindClient: TURNChannelBindClient
    package var credentials: TURNRelaySessionCredentials
    package private(set) var turnEndpoint: TURNServerEndpoint?
    package private(set) var relayedTransport: TURNRequestedTransportProtocol
    package var policy: TURNMaintenancePolicy
    package var jitterSeconds: TimeInterval
    package private(set) var scheduler: TURNMaintenanceScheduler
    package private(set) var relayedAddress: STUNMappedAddress?
    package private(set) var channelBinding: TURNRelayChannelBinding?
    package private(set) var candidate: ICECandidate?
    package private(set) var permissionID: TURNMaintenanceScheduler.PermissionID?

    package init(
        stunTransport: any STUNDatagramTransport,
        credentials: TURNRelaySessionCredentials,
        turnEndpoint: TURNServerEndpoint? = nil,
        relayedTransport: TURNRequestedTransportProtocol = .udp,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0
    ) {
        self.allocationClient = TURNAllocationClient(transport: stunTransport)
        self.refreshClient = TURNRefreshClient(transport: stunTransport)
        self.createPermissionClient = TURNCreatePermissionClient(transport: stunTransport)
        self.channelBindClient = TURNChannelBindClient(transport: stunTransport)
        self.credentials = credentials
        self.turnEndpoint = turnEndpoint
        self.relayedTransport = relayedTransport
        self.policy = policy
        self.jitterSeconds = jitterSeconds
        self.scheduler = TURNMaintenanceScheduler()
        self.candidate = nil
    }

    package init(
        stunTransport: any STUNDatagramTransport,
        configuration: TURNRelaySessionConfiguration,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0
    ) {
        self.init(
            stunTransport: stunTransport,
            credentials: configuration.credentials,
            turnEndpoint: configuration.endpoint,
            relayedTransport: configuration.relayedTransport,
            policy: policy,
            jitterSeconds: jitterSeconds
        )
    }

    package init(
        allocationClient: TURNAllocationClient,
        refreshClient: TURNRefreshClient,
        createPermissionClient: TURNCreatePermissionClient,
        channelBindClient: TURNChannelBindClient,
        credentials: TURNRelaySessionCredentials,
        turnEndpoint: TURNServerEndpoint? = nil,
        relayedTransport: TURNRequestedTransportProtocol = .udp,
        policy: TURNMaintenancePolicy = .standard,
        jitterSeconds: TimeInterval = 0,
        scheduler: TURNMaintenanceScheduler = TURNMaintenanceScheduler()
    ) {
        self.allocationClient = allocationClient
        self.refreshClient = refreshClient
        self.createPermissionClient = createPermissionClient
        self.channelBindClient = channelBindClient
        self.credentials = credentials
        self.turnEndpoint = turnEndpoint
        self.relayedTransport = relayedTransport
        self.policy = policy
        self.jitterSeconds = jitterSeconds
        self.scheduler = scheduler
        self.candidate = nil
    }

    package func transportMetadata(after now: TimeInterval) -> TURNRelaySessionTransportMetadata? {
        guard let relayedAddress, let channelBinding, let candidate, let permissionID else {
            return nil
        }

        return TURNRelaySessionTransportMetadata(
            turnEndpoint: turnEndpoint,
            relayedTransport: relayedTransport,
            relayedAddress: relayedAddress,
            peerAddress: channelBinding.peerAddress,
            channelNumber: channelBinding.channelNumber,
            permissionID: permissionID,
            candidate: candidate,
            nextMaintenanceDeadline: scheduler.nextDeadline(after: now)
        )
    }

    package mutating func setupRelay(
        peerAddress: STUNMappedAddress,
        channelNumber: UInt16,
        datagramTransport: any MediaDatagramTransport,
        at now: TimeInterval,
        permissionID: TURNMaintenanceScheduler.PermissionID? = nil,
        relayedTransport: TURNRequestedTransportProtocol? = nil,
        allocationLifetimeSeconds: UInt32? = nil,
        permissionLifetimeSeconds: UInt32 = TURNMaintenancePolicy.defaultPermissionLifetimeSeconds,
        foundation: String? = nil,
        localPreference: UInt16 = TURNRelayCandidateFactory.defaultLocalPreference,
        transactionIDs: TURNRelaySessionTransactionIDs = TURNRelaySessionTransactionIDs(),
        includeFingerprint: Bool = true,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) throws -> TURNRelaySessionSetupResult {
        let requestedRelayedTransport = relayedTransport ?? self.relayedTransport
        let allocation = try allocationClient.allocate(
            relayedTransport: requestedRelayedTransport,
            username: credentials.username,
            password: credentials.password,
            lifetimeSeconds: allocationLifetimeSeconds,
            transactionID: transactionIDs.allocation,
            authenticatedTransactionID: transactionIDs.authenticatedAllocation,
            staleNonceRetryTransactionID: transactionIDs.staleNonceAllocationRetry,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )
        let binding = try TURNRelayChannelBinding(
            channelNumber: channelNumber,
            peerAddress: peerAddress
        )
        let createPermission = try createPermissionClient.createPermission(
            peerAddresses: [peerAddress],
            username: credentials.username,
            realm: credentials.realm,
            nonce: credentials.nonce,
            password: credentials.password,
            transactionID: transactionIDs.createPermission,
            staleNonceRetryTransactionID: transactionIDs.staleNonceCreatePermissionRetry,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )
        let channelBind = try channelBindClient.channelBind(
            channelNumber: channelNumber,
            peerAddress: peerAddress,
            username: credentials.username,
            realm: credentials.realm,
            nonce: credentials.nonce,
            password: credentials.password,
            transactionID: transactionIDs.channelBind,
            staleNonceRetryTransactionID: transactionIDs.staleNonceChannelBindRetry,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )
        let candidatePlan = TURNRelayCandidateFactory.makePlan(
            relayedAddress: allocation.relayedAddress,
            channelBinding: binding,
            foundation: foundation,
            localPreference: localPreference
        )
        let relayTransport = try TURNRelayTransport(
            datagramTransport: datagramTransport,
            channelBindings: [binding]
        )
        let resolvedPermissionID = permissionID ?? Self.permissionID(for: peerAddress)
        var nextScheduler = TURNMaintenanceScheduler()
        nextScheduler.recordAllocationRefreshSuccess(
            at: now,
            lifetimeSeconds: allocation.lifetimeSeconds,
            policy: policy,
            jitterSeconds: jitterSeconds
        )
        nextScheduler.recordPermissionRefreshSuccess(
            id: resolvedPermissionID,
            at: now,
            lifetimeSeconds: permissionLifetimeSeconds,
            policy: policy,
            jitterSeconds: jitterSeconds
        )

        scheduler = nextScheduler
        relayedAddress = allocation.relayedAddress
        channelBinding = binding
        candidate = candidatePlan.candidate
        self.permissionID = resolvedPermissionID
        self.relayedTransport = requestedRelayedTransport

        let metadata = TURNRelaySessionTransportMetadata(
            turnEndpoint: turnEndpoint,
            relayedTransport: requestedRelayedTransport,
            relayedAddress: allocation.relayedAddress,
            peerAddress: peerAddress,
            channelNumber: channelNumber,
            permissionID: resolvedPermissionID,
            candidate: candidatePlan.candidate,
            nextMaintenanceDeadline: scheduler.nextDeadline(after: now)
        )
        return TURNRelaySessionSetupResult(
            allocation: allocation,
            createPermission: createPermission,
            channelBind: channelBind,
            candidatePlan: candidatePlan,
            relayTransport: relayTransport,
            metadata: metadata,
            scheduler: scheduler
        )
    }

    package mutating func setupRelay(
        plan: TURNRelaySessionSetupPlan,
        datagramTransport: any MediaDatagramTransport,
        at now: TimeInterval,
        includeFingerprint: Bool = true,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) throws -> TURNRelaySessionSetupResult {
        credentials = plan.credentials
        turnEndpoint = plan.endpoint
        relayedTransport = plan.relayedTransport

        return try setupRelay(
            peerAddress: plan.peerAddress,
            channelNumber: plan.channelNumber,
            datagramTransport: datagramTransport,
            at: now,
            permissionID: plan.permissionID,
            relayedTransport: plan.relayedTransport,
            allocationLifetimeSeconds: plan.allocationLifetimeSeconds,
            permissionLifetimeSeconds: plan.permissionLifetimeSeconds,
            foundation: plan.foundation,
            localPreference: plan.localPreference,
            transactionIDs: plan.transactionIDs,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )
    }

    package mutating func executeDueMaintenance(
        at now: TimeInterval,
        transactionIDs: TURNRelaySessionMaintenanceTransactionIDs = TURNRelaySessionMaintenanceTransactionIDs(),
        includeFingerprint: Bool = true,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) async -> [TURNMaintenanceExecutionResult] {
        let credentials = credentials
        let refreshClient = refreshClient
        let createPermissionClient = createPermissionClient
        let peerAddress = channelBinding?.peerAddress
        let activePermissionID = permissionID
        let allocationLifetimeSeconds = scheduler.allocation?.lifetimeSeconds ?? 600
        let permissionLifetimeSecondsByID = scheduler.permissions.mapValues(\.lifetimeSeconds)
        let executor = TURNMaintenanceExecutor(
            policy: policy,
            jitterSeconds: jitterSeconds,
            refreshAllocation: {
                let result = try refreshClient.refresh(
                    username: credentials.username,
                    realm: credentials.realm,
                    nonce: credentials.nonce,
                    password: credentials.password,
                    lifetimeSeconds: allocationLifetimeSeconds,
                    transactionID: transactionIDs.allocationRefresh,
                    staleNonceRetryTransactionID: transactionIDs.staleNonceAllocationRefreshRetry,
                    includeFingerprint: includeFingerprint,
                    requireResponseMessageIntegrity: requireResponseMessageIntegrity,
                    requireResponseFingerprint: requireResponseFingerprint
                )
                return result.lifetimeSeconds
            },
            refreshPermission: { id in
                guard id == activePermissionID else {
                    throw TURNRelaySessionError.unknownPermission(id)
                }
                guard let peerAddress else {
                    throw TURNRelaySessionError.setupRequired
                }

                _ = try createPermissionClient.createPermission(
                    peerAddresses: [peerAddress],
                    username: credentials.username,
                    realm: credentials.realm,
                    nonce: credentials.nonce,
                    password: credentials.password,
                    transactionID: transactionIDs.createPermissionRefresh,
                    staleNonceRetryTransactionID: transactionIDs.staleNonceCreatePermissionRefreshRetry,
                    includeFingerprint: includeFingerprint,
                    requireResponseMessageIntegrity: requireResponseMessageIntegrity,
                    requireResponseFingerprint: requireResponseFingerprint
                )
                return permissionLifetimeSecondsByID[id] ?? TURNMaintenancePolicy.defaultPermissionLifetimeSeconds
            }
        )

        return await executeDueMaintenance(executor: executor, at: now)
    }

    package mutating func executeDueMaintenance(
        executor: TURNMaintenanceExecutor,
        at now: TimeInterval
    ) async -> [TURNMaintenanceExecutionResult] {
        await executor.executeDueActions(scheduler: &scheduler, at: now)
    }

    package func dueMaintenanceActions(at now: TimeInterval) -> [TURNMaintenanceScheduledAction] {
        scheduler.dueActions(at: now)
    }

    package func nextMaintenanceDeadline(after now: TimeInterval) -> TimeInterval? {
        scheduler.nextDeadline(after: now)
    }

    package static func permissionID(for peerAddress: STUNMappedAddress) -> TURNMaintenanceScheduler.PermissionID {
        "\(peerAddress.address):\(peerAddress.port)"
    }
}
