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

package actor OpenSSLDTLSApplicationDataTransport {
    private let session: OpenSSLDTLSSession
    private let transport: any MediaDatagramTransport
    private var isClosed = false

    package init(
        identity: DTLSSRTPIdentity,
        role: DTLSSRTPRole,
        transport: any MediaDatagramTransport,
        profiles: [SRTPProtectionProfile] = [.aes128CMHMACSHA180, .aes128CMHMACSHA132]
    ) throws {
        guard let storage = identity.storage else {
            throw DTLSSRTPError.dtlsIdentityUnavailable("OpenSSL DTLS identity is unavailable.")
        }

        self.session = try OpenSSLDTLSSession(identity: storage, role: role, profiles: profiles)
        self.transport = transport
    }

    package func performHandshake(
        role: DTLSSRTPRole,
        expectedRemoteFingerprint: DTLSSignature,
        receiveAttemptLimit: Int = 64
    ) async throws -> DTLSSRTPHandshakeResult {
        try ensureOpen()

        var completed = false
        for _ in 0..<max(1, receiveAttemptLimit) {
            try ensureOpen()
            let status = try session.handshakeStep(completed: &completed)
            try await flushOutbound()
            try ensureOpen()
            if completed {
                return try session.handshakeResult(
                    role: role,
                    expectedRemoteFingerprint: expectedRemoteFingerprint
                )
            }
            guard status == LKN_DTLS_WANT_READ || status == LKN_DTLS_OK else {
                throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
            }

            let inbound = try await transport.receive()
            try ensureOpen()
            try session.provide(inbound)
        }

        throw DTLSSRTPError.dtlsHandshakeFailed("OpenSSL DTLS handshake did not complete before the receive attempt limit.")
    }

    package func send(_ data: Data) async throws {
        try ensureOpen()
        try session.writeApplicationData(data)
        try await flushOutbound()
    }

    package func receive(maxByteCount: Int = Int(UInt16.max)) async throws -> Data {
        try ensureOpen()

        while true {
            try ensureOpen()
            if let applicationData = try session.readApplicationData(maxByteCount: maxByteCount) {
                try await flushOutbound()
                return applicationData
            }

            let inbound = try await transport.receive()
            try ensureOpen()
            try session.provide(inbound)
            try await flushOutbound()
        }
    }

    package func close() {
        guard !isClosed else {
            return
        }

        isClosed = true
        session.close()
    }

    private func ensureOpen() throws {
        guard !isClosed else {
            throw SecureMediaTransportError.transportClosed
        }
    }

    private func flushOutbound() async throws {
        let datagrams = try session.outboundDatagrams()
        for datagram in datagrams {
            try await transport.send(datagram)
        }
    }
}

private final class OpenSSLDTLSSession {
    private var raw: OpaquePointer?

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
        guard let raw else {
            return
        }

        self.raw = nil
        lkn_dtls_session_free(raw)
    }

    func provide(_ datagram: Data) throws {
        let raw = try requireRaw()
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
        let raw = try requireRaw()
        var isComplete: Int32 = 0
        let status = lkn_dtls_session_do_handshake(raw, &isComplete)
        completed = isComplete != 0
        guard status == LKN_DTLS_OK || status == LKN_DTLS_WANT_READ else {
            throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
        }
        return status
    }

    func writeApplicationData(_ data: Data) throws {
        let raw = try requireRaw()
        let status = data.withUnsafeBytes { bytes in
            lkn_dtls_session_write_application_data(
                raw,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                data.count
            )
        }
        guard status == LKN_DTLS_OK else {
            throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
        }
    }

    func readApplicationData(maxByteCount: Int) throws -> Data? {
        let raw = try requireRaw()
        let capacity = max(1, maxByteCount)
        var data = Data(repeating: 0, count: capacity)
        var length = 0
        let status = data.withUnsafeMutableBytes { bytes in
            lkn_dtls_session_read_application_data(
                raw,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                capacity,
                &length
            )
        }
        if status == LKN_DTLS_WANT_READ {
            return nil
        }
        guard status == LKN_DTLS_OK else {
            throw DTLSSRTPError.dtlsHandshakeFailed(OpenSSLDTLSIdentityStorage.lastError())
        }
        return Data(data.prefix(length))
    }

    func flushOutbound(to transport: any MediaDatagramTransport) async throws {
        for datagram in try outboundDatagrams() {
            try await transport.send(datagram)
        }
    }

    func outboundDatagrams() throws -> [Data] {
        let raw = try requireRaw()
        var datagrams: [Data] = []
        while true {
            let datagram = try OpenSSLDTLSIdentityStorage.copyBuffer { buffer, capacity, outLength in
                lkn_dtls_session_copy_outbound(raw, buffer, capacity, outLength)
            }
            guard !datagram.isEmpty else {
                return datagrams
            }
            datagrams.append(datagram)
        }
    }

    func handshakeResult(
        role: DTLSSRTPRole,
        expectedRemoteFingerprint: DTLSSignature
    ) throws -> DTLSSRTPHandshakeResult {
        let raw = try requireRaw()
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

    private func requireRaw() throws -> OpaquePointer {
        guard let raw else {
            throw SecureMediaTransportError.transportClosed
        }

        return raw
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
