import CryptoKit
import Foundation

package struct TURNAllocationResult: Equatable, Sendable {
    package var relayedAddress: STUNMappedAddress
    package var lifetimeSeconds: UInt32
    package var response: STUNMessage

    package init(
        relayedAddress: STUNMappedAddress,
        lifetimeSeconds: UInt32,
        response: STUNMessage
    ) {
        self.relayedAddress = relayedAddress
        self.lifetimeSeconds = lifetimeSeconds
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

package enum TURNLongTermCredential {
    package static func messageIntegrityKey(
        username: String,
        realm: String,
        password: String
    ) -> Data {
        Data(Insecure.MD5.hash(data: Data("\(username):\(realm):\(password)".utf8)))
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

        guard response.type == .allocateSuccessResponse else {
            if response.type == .allocateErrorResponse {
                throw TURNAllocationError.allocationFailed(try response.firstAttribute(.errorCode)?.errorCodeValue?.code)
            }

            throw TURNAllocationError.unexpectedResponseType(response.type.rawValue)
        }

        return try allocationResult(from: response)
    }

    private func allocationResult(from response: STUNMessage) throws -> TURNAllocationResult {
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
            response: response
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
