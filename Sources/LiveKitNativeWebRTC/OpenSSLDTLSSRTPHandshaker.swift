import CLiveKitNativeOpenSSL
import Foundation

package final class OpenSSLDTLSIdentityStorage: @unchecked Sendable {
    fileprivate let raw: OpaquePointer

    package init() throws {
        guard let raw = lkn_dtls_identity_create() else {
            throw DTLSSRTPError.dtlsIdentityUnavailable(Self.lastError())
        }
        self.raw = raw
    }

    deinit {
        lkn_dtls_identity_free(raw)
    }

    package var certificateDER: Data {
        get throws {
            try Self.copyBuffer { buffer, capacity, outLength in
                lkn_dtls_identity_copy_certificate_der(raw, buffer, capacity, outLength)
            }
        }
    }

    fileprivate static func copyBuffer(
        _ copy: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> Int32
    ) throws -> Data {
        var length = 0
        guard copy(nil, 0, &length) == LKN_DTLS_OK else {
            throw DTLSSRTPError.dtlsHandshakeFailed(lastError())
        }

        var data = Data(repeating: 0, count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            copy(bytes.bindMemory(to: UInt8.self).baseAddress, length, &length)
        }
        guard status == LKN_DTLS_OK else {
            throw DTLSSRTPError.dtlsHandshakeFailed(lastError())
        }
        return Data(data.prefix(length))
    }

    fileprivate static func lastError() -> String {
        guard let pointer = lkn_dtls_last_error_string() else {
            return "OpenSSL DTLS operation failed."
        }
        let message = String(cString: pointer)
        return message.isEmpty ? "OpenSSL DTLS operation failed." : message
    }
}

package struct DTLSSRTPIdentity: Equatable, Sendable {
    package var fingerprint: DTLSSignature
    package var storage: OpenSSLDTLSIdentityStorage?

    package init(fingerprint: DTLSSignature, storage: OpenSSLDTLSIdentityStorage? = nil) {
        self.fingerprint = fingerprint
        self.storage = storage
    }

    package static func generated() -> DTLSSRTPIdentity {
        do {
            let storage = try OpenSSLDTLSIdentityStorage()
            return try DTLSSRTPIdentity(
                fingerprint: .sha256CertificateFingerprint(certificateDER: storage.certificateDER),
                storage: storage
            )
        } catch {
            return DTLSSRTPIdentity(fingerprint: .random())
        }
    }

    package static func == (lhs: DTLSSRTPIdentity, rhs: DTLSSRTPIdentity) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }
}

package struct OpenSSLDTLSSRTPHandshaker: DTLSSRTPHandshaking {
    package var identity: DTLSSRTPIdentity
    package var receiveAttemptLimit: Int

    package init(
        identity: DTLSSRTPIdentity = .generated(),
        receiveAttemptLimit: Int = 64
    ) {
        self.identity = identity
        self.receiveAttemptLimit = max(1, receiveAttemptLimit)
    }

    package func performHandshake(
        configuration: DTLSSRTPHandshakeConfiguration,
        transport: any MediaDatagramTransport
    ) async throws -> DTLSSRTPHandshakeResult {
        guard let storage = identity.storage else {
            throw DTLSSRTPError.dtlsIdentityUnavailable("OpenSSL DTLS identity is unavailable.")
        }

        let session = try OpenSSLDTLSSession(
            identity: storage,
            role: configuration.role,
            profiles: configuration.useSRTExtension.protectionProfiles
        )
        defer { session.close() }

        var completed = false
        for _ in 0..<receiveAttemptLimit {
            let status = try session.handshakeStep(completed: &completed)
            try await session.flushOutbound(to: transport)
            if completed {
                return try session.handshakeResult(
                    role: configuration.role,
                    expectedRemoteFingerprint: configuration.remoteFingerprint
                )
            }
            guard status == LKN_DTLS_WANT_READ || status == LKN_DTLS_OK else {
                throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
            }

            let inbound = try await transport.receive()
            try session.provide(inbound)
        }

        throw DTLSSRTPError.dtlsHandshakeFailed("OpenSSL DTLS handshake did not complete before the receive attempt limit.")
    }
}

private final class OpenSSLDTLSSession {
    private let raw: OpaquePointer

    init(
        identity: OpenSSLDTLSIdentityStorage,
        role: DTLSSRTPRole,
        profiles: [SRTPProtectionProfile]
    ) throws {
        let profileNames = profiles.map(\.openSSLName).joined(separator: ":")
        guard let raw = lkn_dtls_session_create(
            identity.raw,
            role == .server ? 1 : 0,
            profileNames
        ) else {
            throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
        }
        self.raw = raw
    }

    func close() {
        lkn_dtls_session_free(raw)
    }

    func provide(_ datagram: Data) throws {
        let status = datagram.withUnsafeBytes { bytes in
            lkn_dtls_session_provide_datagram(
                raw,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                datagram.count
            )
        }
        guard status == LKN_DTLS_OK else {
            throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
        }
    }

    func handshakeStep(completed: inout Bool) throws -> Int32 {
        var isComplete: Int32 = 0
        let status = lkn_dtls_session_do_handshake(raw, &isComplete)
        completed = isComplete != 0
        guard status == LKN_DTLS_OK || status == LKN_DTLS_WANT_READ else {
            throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
        }
        return status
    }

    func flushOutbound(to transport: any MediaDatagramTransport) async throws {
        while true {
            let datagram = try OpenSSLDTLSIdentityStorage.copyBuffer { buffer, capacity, outLength in
                lkn_dtls_session_copy_outbound(raw, buffer, capacity, outLength)
            }
            guard !datagram.isEmpty else {
                return
            }
            try await transport.send(datagram)
        }
    }

    func handshakeResult(
        role: DTLSSRTPRole,
        expectedRemoteFingerprint: DTLSSignature
    ) throws -> DTLSSRTPHandshakeResult {
        let profileIdentifier = lkn_dtls_session_selected_srtp_profile(raw)
        guard profileIdentifier != 0 else {
            throw DTLSSRTPError.missingSelectedSRTPProtectionProfile
        }
        let protectionProfile = try SRTPProtectionProfile(identifier: profileIdentifier)
        let peerCertificate = try OpenSSLDTLSIdentityStorage.copyBuffer { buffer, capacity, outLength in
            lkn_dtls_session_copy_peer_certificate_der(raw, buffer, capacity, outLength)
        }
        guard !peerCertificate.isEmpty else {
            throw DTLSSRTPError.missingPeerDTLSCertificate
        }
        let remoteFingerprint = DTLSSignature.sha256CertificateFingerprint(certificateDER: peerCertificate)
        guard remoteFingerprint == expectedRemoteFingerprint else {
            throw SecureMediaTransportError.remoteFingerprintMismatch(
                expected: expectedRemoteFingerprint,
                actual: remoteFingerprint
            )
        }

        let exporterByteCount = protectionProfile.exporterByteCount
        var exported = Data(repeating: 0, count: exporterByteCount)
        let exportStatus = exported.withUnsafeMutableBytes { bytes in
            lkn_dtls_session_export_keying_material(
                raw,
                SRTPProtectionProfile.exporterLabel,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                exporterByteCount
            )
        }
        guard exportStatus == LKN_DTLS_OK else {
            throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
        }

        return try DTLSSRTPHandshakeResult(
            role: role,
            protectionProfile: protectionProfile,
            exportedKeyingMaterial: exported,
            remoteFingerprint: remoteFingerprint
        )
    }
}

private extension SRTPProtectionProfile {
    var openSSLName: String {
        switch identifier {
        case Self.aes128CMHMACSHA180.identifier:
            return "SRTP_AES128_CM_SHA1_80"
        case Self.aes128CMHMACSHA132.identifier:
            return "SRTP_AES128_CM_SHA1_32"
        default:
            return name
        }
    }
}
