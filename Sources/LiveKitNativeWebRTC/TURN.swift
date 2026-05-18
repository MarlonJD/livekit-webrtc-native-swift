import CryptoKit
import Foundation

package struct TURNAllocationResult: Equatable, Sendable {
    package var relayedAddress: STUNMappedAddress
    package var lifetimeSeconds: UInt32
    package var response: STUNMessage
    package var credentials: TURNRelaySessionCredentials?

    package init(
        relayedAddress: STUNMappedAddress,
        lifetimeSeconds: UInt32,
        response: STUNMessage,
        credentials: TURNRelaySessionCredentials? = nil
    ) {
        self.relayedAddress = relayedAddress
        self.lifetimeSeconds = lifetimeSeconds
        self.response = response
        self.credentials = credentials
    }
}

package struct TURNRefreshResult: Equatable, Sendable {
    package var lifetimeSeconds: UInt32
    package var response: STUNMessage

    package init(
        lifetimeSeconds: UInt32,
        response: STUNMessage
    ) {
        self.lifetimeSeconds = lifetimeSeconds
        self.response = response
    }
}

package struct TURNCreatePermissionResult: Equatable, Sendable {
    package var response: STUNMessage

    package init(response: STUNMessage) {
        self.response = response
    }
}

package struct TURNChannelBindResult: Equatable, Sendable {
    package var response: STUNMessage

    package init(response: STUNMessage) {
        self.response = response
    }
}

package enum TURNAllocationError: Error, Equatable, Sendable {
    case transactionMismatch
    case unexpectedResponseType(UInt16)
    case missingRelayedAddress
    case invalidLifetime
    case invalidMessageIntegrity
    case invalidFingerprint
    case authenticationChallengeMissingAttributes
    case authenticationChallengeWithoutCredentials
    case allocationFailed(Int?)
}

package enum TURNRefreshError: Error, Equatable, Sendable {
    case transactionMismatch
    case unexpectedResponseType(UInt16)
    case invalidLifetime
    case invalidMessageIntegrity
    case invalidFingerprint
    case refreshFailed(Int?)
}

package enum TURNCreatePermissionError: Error, Equatable, Sendable {
    case transactionMismatch
    case unexpectedResponseType(UInt16)
    case invalidMessageIntegrity
    case invalidFingerprint
    case createPermissionFailed(Int?)
}

package enum TURNChannelBindError: Error, Equatable, Sendable {
    case transactionMismatch
    case unexpectedResponseType(UInt16)
    case invalidMessageIntegrity
    case invalidFingerprint
    case channelBindFailed(Int?)
}

package enum TURNLongTermCredential {
    package static func messageIntegrityKey(
        username: String,
        realm: String,
        password: String
    ) -> Data {
        Data(Insecure.MD5.hash(data: Data("\(username):\(realm):\(password)".utf8)))
    }
}

private let turnStaleNonceErrorCode = 438

private func turnErrorCode(from response: STUNMessage) throws -> Int? {
    try response.firstAttribute(.errorCode)?.errorCodeValue?.code
}

private func turnStaleNonce(from response: STUNMessage) throws -> String? {
    guard try turnErrorCode(from: response) == turnStaleNonceErrorCode else {
        return nil
    }

    return try response.firstAttribute(.nonce)?.stringValue
}

package struct TURNRefreshClient: Sendable {
    package var transport: any STUNDatagramTransport

    package init(transport: any STUNDatagramTransport) {
        self.transport = transport
    }

    package func refresh(
        username: String,
        realm: String,
        nonce: String,
        password: String,
        lifetimeSeconds: UInt32 = 600,
        transactionID: STUNTransactionID = .random(),
        staleNonceRetryTransactionID: STUNTransactionID = .random(),
        includeFingerprint: Bool = true,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) throws -> TURNRefreshResult {
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: username,
            realm: realm,
            password: password
        )
        let response = try sendRefreshRequest(
            username: username,
            realm: realm,
            nonce: nonce,
            key: key,
            lifetimeSeconds: lifetimeSeconds,
            transactionID: transactionID,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )

        if response.type == .refreshErrorResponse,
           let retryNonce = try turnStaleNonce(from: response) {
            return try refreshResult(from: sendRefreshRequest(
                username: username,
                realm: realm,
                nonce: retryNonce,
                key: key,
                lifetimeSeconds: lifetimeSeconds,
                transactionID: staleNonceRetryTransactionID,
                includeFingerprint: includeFingerprint,
                requireResponseMessageIntegrity: requireResponseMessageIntegrity,
                requireResponseFingerprint: requireResponseFingerprint
            ))
        }

        return try refreshResult(from: response)
    }

    private func sendRefreshRequest(
        username: String,
        realm: String,
        nonce: String,
        key: Data,
        lifetimeSeconds: UInt32,
        transactionID: STUNTransactionID,
        includeFingerprint: Bool,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws -> STUNMessage {
        let request = TURNRefreshRequestFactory.makeRefreshRequest(
            username: username,
            realm: realm,
            nonce: nonce,
            lifetimeSeconds: lifetimeSeconds,
            transactionID: transactionID
        )
        let responseData = try transport.send(try request.encoded(
            messageIntegrityKey: key,
            includeFingerprint: includeFingerprint
        ))
        let response = try STUNMessage(decoding: responseData)

        guard response.transactionID == transactionID else {
            throw TURNRefreshError.transactionMismatch
        }

        try validateProtection(
            response,
            messageIntegrityKey: key,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )

        return response
    }

    private func refreshResult(from response: STUNMessage) throws -> TURNRefreshResult {
        guard response.type == .refreshSuccessResponse else {
            if response.type == .refreshErrorResponse {
                throw TURNRefreshError.refreshFailed(try turnErrorCode(from: response))
            }

            throw TURNRefreshError.unexpectedResponseType(response.type.rawValue)
        }

        let lifetimeSeconds: UInt32
        if let lifetimeAttribute = response.firstAttribute(.lifetime) {
            guard let parsedLifetimeSeconds = lifetimeAttribute.uint32Value else {
                throw TURNRefreshError.invalidLifetime
            }

            lifetimeSeconds = parsedLifetimeSeconds
        } else {
            lifetimeSeconds = 600
        }

        return TURNRefreshResult(
            lifetimeSeconds: lifetimeSeconds,
            response: response
        )
    }

    private func validateProtection(
        _ response: STUNMessage,
        messageIntegrityKey: Data,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws {
        if response.firstAttribute(.fingerprint) != nil || requireResponseFingerprint {
            guard try response.validatesFingerprint() else {
                throw TURNRefreshError.invalidFingerprint
            }
        }

        if response.firstAttribute(.messageIntegrity) != nil || requireResponseMessageIntegrity {
            guard try response.validatesMessageIntegrity(key: messageIntegrityKey) else {
                throw TURNRefreshError.invalidMessageIntegrity
            }
        }
    }
}

package struct TURNCreatePermissionClient: Sendable {
    package var transport: any STUNDatagramTransport

    package init(transport: any STUNDatagramTransport) {
        self.transport = transport
    }

    package func createPermission(
        peerAddresses: [STUNMappedAddress],
        username: String,
        realm: String,
        nonce: String,
        password: String,
        transactionID: STUNTransactionID = .random(),
        staleNonceRetryTransactionID: STUNTransactionID = .random(),
        includeFingerprint: Bool = true,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) throws -> TURNCreatePermissionResult {
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: username,
            realm: realm,
            password: password
        )
        let response = try sendCreatePermissionRequest(
            peerAddresses: peerAddresses,
            username: username,
            realm: realm,
            nonce: nonce,
            key: key,
            transactionID: transactionID,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )

        if response.type == .createPermissionErrorResponse,
           let retryNonce = try turnStaleNonce(from: response) {
            return try createPermissionResult(from: sendCreatePermissionRequest(
                peerAddresses: peerAddresses,
                username: username,
                realm: realm,
                nonce: retryNonce,
                key: key,
                transactionID: staleNonceRetryTransactionID,
                includeFingerprint: includeFingerprint,
                requireResponseMessageIntegrity: requireResponseMessageIntegrity,
                requireResponseFingerprint: requireResponseFingerprint
            ))
        }

        return try createPermissionResult(from: response)
    }

    private func sendCreatePermissionRequest(
        peerAddresses: [STUNMappedAddress],
        username: String,
        realm: String,
        nonce: String,
        key: Data,
        transactionID: STUNTransactionID,
        includeFingerprint: Bool,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws -> STUNMessage {
        let request = try TURNCreatePermissionRequestFactory.makeCreatePermissionRequest(
            peerAddresses: peerAddresses,
            username: username,
            realm: realm,
            nonce: nonce,
            transactionID: transactionID
        )
        let responseData = try transport.send(try request.encoded(
            messageIntegrityKey: key,
            includeFingerprint: includeFingerprint
        ))
        let response = try STUNMessage(decoding: responseData)

        guard response.transactionID == transactionID else {
            throw TURNCreatePermissionError.transactionMismatch
        }

        try validateProtection(
            response,
            messageIntegrityKey: key,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )

        return response
    }

    private func createPermissionResult(from response: STUNMessage) throws -> TURNCreatePermissionResult {
        guard response.type == .createPermissionSuccessResponse else {
            if response.type == .createPermissionErrorResponse {
                throw TURNCreatePermissionError.createPermissionFailed(try turnErrorCode(from: response))
            }

            throw TURNCreatePermissionError.unexpectedResponseType(response.type.rawValue)
        }

        return TURNCreatePermissionResult(response: response)
    }

    private func validateProtection(
        _ response: STUNMessage,
        messageIntegrityKey: Data,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws {
        if response.firstAttribute(.fingerprint) != nil || requireResponseFingerprint {
            guard try response.validatesFingerprint() else {
                throw TURNCreatePermissionError.invalidFingerprint
            }
        }

        if response.firstAttribute(.messageIntegrity) != nil || requireResponseMessageIntegrity {
            guard try response.validatesMessageIntegrity(key: messageIntegrityKey) else {
                throw TURNCreatePermissionError.invalidMessageIntegrity
            }
        }
    }
}

package struct TURNChannelBindClient: Sendable {
    package var transport: any STUNDatagramTransport

    package init(transport: any STUNDatagramTransport) {
        self.transport = transport
    }

    package func channelBind(
        channelNumber: UInt16,
        peerAddress: STUNMappedAddress,
        username: String,
        realm: String,
        nonce: String,
        password: String,
        transactionID: STUNTransactionID = .random(),
        staleNonceRetryTransactionID: STUNTransactionID = .random(),
        includeFingerprint: Bool = true,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) throws -> TURNChannelBindResult {
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: username,
            realm: realm,
            password: password
        )
        let response = try sendChannelBindRequest(
            channelNumber: channelNumber,
            peerAddress: peerAddress,
            username: username,
            realm: realm,
            nonce: nonce,
            key: key,
            transactionID: transactionID,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )

        if response.type == .channelBindErrorResponse,
           let retryNonce = try turnStaleNonce(from: response) {
            return try channelBindResult(from: sendChannelBindRequest(
                channelNumber: channelNumber,
                peerAddress: peerAddress,
                username: username,
                realm: realm,
                nonce: retryNonce,
                key: key,
                transactionID: staleNonceRetryTransactionID,
                includeFingerprint: includeFingerprint,
                requireResponseMessageIntegrity: requireResponseMessageIntegrity,
                requireResponseFingerprint: requireResponseFingerprint
            ))
        }

        return try channelBindResult(from: response)
    }

    private func sendChannelBindRequest(
        channelNumber: UInt16,
        peerAddress: STUNMappedAddress,
        username: String,
        realm: String,
        nonce: String,
        key: Data,
        transactionID: STUNTransactionID,
        includeFingerprint: Bool,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws -> STUNMessage {
        let request = try TURNChannelBindRequestFactory.makeChannelBindRequest(
            channelNumber: channelNumber,
            peerAddress: peerAddress,
            username: username,
            realm: realm,
            nonce: nonce,
            transactionID: transactionID
        )
        let responseData = try transport.send(try request.encoded(
            messageIntegrityKey: key,
            includeFingerprint: includeFingerprint
        ))
        let response = try STUNMessage(decoding: responseData)

        guard response.transactionID == transactionID else {
            throw TURNChannelBindError.transactionMismatch
        }

        try validateProtection(
            response,
            messageIntegrityKey: key,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )

        return response
    }

    private func channelBindResult(from response: STUNMessage) throws -> TURNChannelBindResult {
        guard response.type == .channelBindSuccessResponse else {
            if response.type == .channelBindErrorResponse {
                throw TURNChannelBindError.channelBindFailed(try turnErrorCode(from: response))
            }

            throw TURNChannelBindError.unexpectedResponseType(response.type.rawValue)
        }

        return TURNChannelBindResult(response: response)
    }

    private func validateProtection(
        _ response: STUNMessage,
        messageIntegrityKey: Data,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws {
        if response.firstAttribute(.fingerprint) != nil || requireResponseFingerprint {
            guard try response.validatesFingerprint() else {
                throw TURNChannelBindError.invalidFingerprint
            }
        }

        if response.firstAttribute(.messageIntegrity) != nil || requireResponseMessageIntegrity {
            guard try response.validatesMessageIntegrity(key: messageIntegrityKey) else {
                throw TURNChannelBindError.invalidMessageIntegrity
            }
        }
    }
}

package struct TURNAllocationClient: Sendable {
    package var transport: any STUNDatagramTransport

    package init(transport: any STUNDatagramTransport) {
        self.transport = transport
    }

    package func allocate(
        relayedTransport: TURNRequestedTransportProtocol = .udp,
        username: String? = nil,
        password: String? = nil,
        lifetimeSeconds: UInt32? = nil,
        transactionID: STUNTransactionID = .random(),
        authenticatedTransactionID: STUNTransactionID = .random(),
        staleNonceRetryTransactionID: STUNTransactionID = .random(),
        includeFingerprint: Bool = true,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) throws -> TURNAllocationResult {
        let request = TURNAllocateRequestFactory.makeAllocateRequest(
            relayedTransport: relayedTransport,
            lifetimeSeconds: lifetimeSeconds,
            transactionID: transactionID
        )
        let responseData = try transport.send(try request.encoded(includeFingerprint: includeFingerprint))
        let response = try STUNMessage(decoding: responseData)

        guard response.transactionID == transactionID else {
            throw TURNAllocationError.transactionMismatch
        }

        try validateProtection(
            response,
            messageIntegrityKey: nil,
            requireResponseMessageIntegrity: false,
            requireResponseFingerprint: requireResponseFingerprint
        )

        if response.type == .allocateSuccessResponse {
            try validateProtection(
                response,
                messageIntegrityKey: nil,
                requireResponseMessageIntegrity: requireResponseMessageIntegrity,
                requireResponseFingerprint: requireResponseFingerprint
            )
            return try allocationResult(from: response)
        }

        guard response.type == .allocateErrorResponse else {
            throw TURNAllocationError.unexpectedResponseType(response.type.rawValue)
        }

        guard try response.firstAttribute(.errorCode)?.errorCodeValue?.code == 401 else {
            throw TURNAllocationError.allocationFailed(try response.firstAttribute(.errorCode)?.errorCodeValue?.code)
        }

        guard let username, let password else {
            throw TURNAllocationError.authenticationChallengeWithoutCredentials
        }

        guard let realm = try response.firstAttribute(.realm)?.stringValue,
              let nonce = try response.firstAttribute(.nonce)?.stringValue
        else {
            throw TURNAllocationError.authenticationChallengeMissingAttributes
        }

        return try allocateWithLongTermCredentials(
            relayedTransport: relayedTransport,
            username: username,
            realm: realm,
            nonce: nonce,
            password: password,
            lifetimeSeconds: lifetimeSeconds,
            transactionID: authenticatedTransactionID,
            staleNonceRetryTransactionID: staleNonceRetryTransactionID,
            includeFingerprint: includeFingerprint,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )
    }

    private func allocateWithLongTermCredentials(
        relayedTransport: TURNRequestedTransportProtocol,
        username: String,
        realm: String,
        nonce: String,
        password: String,
        lifetimeSeconds: UInt32?,
        transactionID: STUNTransactionID,
        staleNonceRetryTransactionID: STUNTransactionID?,
        includeFingerprint: Bool,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws -> TURNAllocationResult {
        let key = TURNLongTermCredential.messageIntegrityKey(
            username: username,
            realm: realm,
            password: password
        )
        let request = TURNAllocateRequestFactory.makeAllocateRequest(
            relayedTransport: relayedTransport,
            username: username,
            realm: realm,
            nonce: nonce,
            lifetimeSeconds: lifetimeSeconds,
            transactionID: transactionID
        )
        let responseData = try transport.send(try request.encoded(
            messageIntegrityKey: key,
            includeFingerprint: includeFingerprint
        ))
        let response = try STUNMessage(decoding: responseData)

        guard response.transactionID == transactionID else {
            throw TURNAllocationError.transactionMismatch
        }

        try validateProtection(
            response,
            messageIntegrityKey: key,
            requireResponseMessageIntegrity: requireResponseMessageIntegrity,
            requireResponseFingerprint: requireResponseFingerprint
        )

        if response.type == .allocateErrorResponse,
           let staleNonceRetryTransactionID,
           let retryNonce = try turnStaleNonce(from: response) {
            return try allocateWithLongTermCredentials(
                relayedTransport: relayedTransport,
                username: username,
                realm: realm,
                nonce: retryNonce,
                password: password,
                lifetimeSeconds: lifetimeSeconds,
                transactionID: staleNonceRetryTransactionID,
                staleNonceRetryTransactionID: nil,
                includeFingerprint: includeFingerprint,
                requireResponseMessageIntegrity: requireResponseMessageIntegrity,
                requireResponseFingerprint: requireResponseFingerprint
            )
        }

        guard response.type == .allocateSuccessResponse else {
            if response.type == .allocateErrorResponse {
                throw TURNAllocationError.allocationFailed(try turnErrorCode(from: response))
            }

            throw TURNAllocationError.unexpectedResponseType(response.type.rawValue)
        }

        return try allocationResult(
            from: response,
            credentials: TURNRelaySessionCredentials(
                username: username,
                realm: realm,
                nonce: nonce,
                password: password
            )
        )
    }

    private func allocationResult(
        from response: STUNMessage,
        credentials: TURNRelaySessionCredentials? = nil
    ) throws -> TURNAllocationResult {
        guard let relayedAddress = try response.firstAttribute(.xorRelayedAddress)?.xorRelayedAddressValue else {
            throw TURNAllocationError.missingRelayedAddress
        }

        let lifetimeSeconds: UInt32
        if let lifetimeAttribute = response.firstAttribute(.lifetime) {
            guard let parsedLifetimeSeconds = lifetimeAttribute.uint32Value else {
                throw TURNAllocationError.invalidLifetime
            }

            lifetimeSeconds = parsedLifetimeSeconds
        } else {
            lifetimeSeconds = 600
        }

        return TURNAllocationResult(
            relayedAddress: relayedAddress,
            lifetimeSeconds: lifetimeSeconds,
            response: response,
            credentials: credentials
        )
    }

    private func validateProtection(
        _ response: STUNMessage,
        messageIntegrityKey: Data?,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws {
        if response.firstAttribute(.fingerprint) != nil || requireResponseFingerprint {
            guard try response.validatesFingerprint() else {
                throw TURNAllocationError.invalidFingerprint
            }
        }

        if response.firstAttribute(.messageIntegrity) != nil || requireResponseMessageIntegrity {
            guard let messageIntegrityKey,
                  try response.validatesMessageIntegrity(key: messageIntegrityKey)
            else {
                throw TURNAllocationError.invalidMessageIntegrity
            }
        }
    }
}
