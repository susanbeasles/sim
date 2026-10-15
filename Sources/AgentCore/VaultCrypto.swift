import Foundation

#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Security
#endif

public struct PIVIdentitySummary: Hashable, Sendable {
    public let certificateSHA256: String
    public let subject: String
    public let keyType: String
    public let keyBits: Int
    public let tokenID: String
    public let rsaOAEPCompatible: Bool

    public init(
        certificateSHA256: String,
        subject: String,
        keyType: String,
        keyBits: Int,
        tokenID: String,
        rsaOAEPCompatible: Bool
    ) {
        self.certificateSHA256 = certificateSHA256
        self.subject = subject
        self.keyType = keyType
        self.keyBits = keyBits
        self.tokenID = tokenID
        self.rsaOAEPCompatible = rsaOAEPCompatible
    }
}

public struct EncryptedArtifactResult: Sendable {
    public let plaintextSHA256: String
    public let ciphertextSHA256: String
    public let plaintextBytes: UInt64
    public let ciphertextBytes: UInt64
    public let chunkBytes: Int
    public let wrappedKey: VaultKeyWrap
}

public struct HardwareVaultCrypto: Sendable {
    public static let defaultChunkBytes = 8 * 1024 * 1024
    private static let magic = Data("AGTVLT01".utf8)
    private static let version: UInt32 = 1

    public init() {}

    public func unwrapDataKey(wrapped: Data, recipientCertificateSHA256: String) throws -> Data {
        #if canImport(CryptoKit) && canImport(Security)
        let fingerprint = Self.normalizeFingerprint(recipientCertificateSHA256)
        guard fingerprint.count == 64 else { throw AgentError.malformed("invalid PIV certificate fingerprint") }
        let identity = try macIdentity(fingerprint: fingerprint)
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey, Self.hardwareTokenID(privateKey) != nil,
              Self.isRSA(privateKey),
              SecKeyIsAlgorithmSupported(privateKey, .decrypt, .rsaEncryptionOAEPSHA256) else {
            throw AgentError.authorizationRequired("hardware PIV RSA-OAEP key unavailable")
        }
        FileHandle.standardError.write(Data("Touch YubiKey to unlock the fleet session key.\n".utf8))
        var error: Unmanaged<CFError>?
        guard let result = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, wrapped as CFData, &error) else {
            throw AgentError.authorizationRequired("hardware fleet key unwrap failed: \(Self.describe(error))")
        }
        let data = result as Data
        guard data.count == 32 else { throw AgentError.trustFailure("fleet data key is not 32 bytes") }
        return data
        #else
        throw AgentError.unsupported("fleet key unwrap requires macOS Security.framework and a hardware PIV identity")
        #endif
    }

    public func identities() throws -> [PIVIdentitySummary] {
        #if canImport(CryptoKit) && canImport(Security)
        return try macIdentities().compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
                throw AgentError.trustFailure("could not read certificate from hardware identity")
            }
            var privateKey: SecKey?
            guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, let privateKey else {
                return nil
            }
            guard let tokenID = Self.hardwareTokenID(privateKey) else {
                return nil
            }
            guard let publicKey = SecCertificateCopyKey(certificate) else {
                throw AgentError.trustFailure("hardware identity has no public key")
            }
            
        guard let cfAttrs = SecKeyCopyAttributes(publicKey) else {
            throw AgentError.trustFailure("hardware public key has no attributes")
        }
        let attrs = cfAttrs as NSDictionary

            let type = (attrs[kSecAttrKeyType] as? String) ?? String(describing: attrs[kSecAttrKeyType] ?? "unknown")
            let bits = (attrs[kSecAttrKeySizeInBits] as? NSNumber)?.intValue ?? 0
            let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "<no subject>"
            let compatible = Self.isRSA(publicKey)
                && Self.isRSA(privateKey)
                && SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionOAEPSHA256)
                && SecKeyIsAlgorithmSupported(privateKey, .decrypt, .rsaEncryptionOAEPSHA256)
            return PIVIdentitySummary(
                certificateSHA256: Self.certificateFingerprint(certificate),
                subject: subject,
                keyType: type,
                keyBits: bits,
                tokenID: tokenID,
                rsaOAEPCompatible: compatible
            )
        }.sorted { $0.subject < $1.subject }
        #else
        throw AgentError.unsupported("PIV identity discovery requires macOS Security.framework")
        #endif
    }

    public func encrypt(
        plaintext: URL,
        ciphertext: URL,
        recipientCertificateSHA256: String,
        chunkBytes: Int = HardwareVaultCrypto.defaultChunkBytes
    ) throws -> EncryptedArtifactResult {
        #if canImport(CryptoKit) && canImport(Security)
        guard chunkBytes >= 64 * 1024, chunkBytes <= 64 * 1024 * 1024 else {
            throw AgentError.invalidArgument("vault chunk size must be between 64 KiB and 64 MiB")
        }
        let fingerprint = Self.normalizeFingerprint(recipientCertificateSHA256)
        let identity = try macIdentity(fingerprint: fingerprint)
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw AgentError.trustFailure("could not read PIV certificate")
        }
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            throw AgentError.trustFailure("PIV certificate has no public key")
        }
        guard Self.isRSA(publicKey), SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionOAEPSHA256) else {
            throw AgentError.unsupported("vault wrapping requires a PIV RSA key supporting RSA-OAEP-SHA256")
        }

        let symmetric = SymmetricKey(size: .bits256)
        let keyData = symmetric.withUnsafeBytes { Data($0) }
        var wrapError: Unmanaged<CFError>?
        guard let wrappedCF = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, keyData as CFData, &wrapError) else {
            throw AgentError.trustFailure("could not wrap vault key: \(Self.describe(wrapError))")
        }
        let wrapped = wrappedCF as Data

        let input = try FileHandle(forReadingFrom: plaintext)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: ciphertext.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: ciphertext)
        defer { try? output.close() }

        var header = Self.magic
        header.append(Self.be(Self.version))
        header.append(Self.be(UInt32(chunkBytes)))
        try output.write(contentsOf: header)

        var index: UInt64 = 0
        var plaintextBytes: UInt64 = 0
        while true {
            let chunk = try input.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            plaintextBytes &+= UInt64(chunk.count)
            let aad = Self.aad(header: header, index: index)
            let sealed = try AES.GCM.seal(chunk, using: symmetric, authenticating: aad)
            guard let combined = sealed.combined else {
                throw AgentError.malformed("CryptoKit did not produce a combined AES-GCM record")
            }
            guard combined.count <= Int(UInt32.max) else { throw AgentError.malformed("encrypted vault chunk is too large") }
            try output.write(contentsOf: Self.be(index))
            try output.write(contentsOf: Self.be(UInt32(combined.count)))
            try output.write(contentsOf: combined)
            index &+= 1
        }
        try output.write(contentsOf: Self.be(UInt64.max))
        try output.write(contentsOf: Self.be(UInt32(0)))
        try output.synchronize()

        let plainDigest = try Digest.sha256(file: plaintext)
        let cipherDigest = try Digest.sha256(file: ciphertext)
        let cipherBytes = try Self.fileSize(ciphertext)
        let actualFingerprint = Self.certificateFingerprint(certificate)
        guard actualFingerprint == fingerprint else {
            throw AgentError.trustFailure("selected PIV certificate changed while staking")
        }
        return EncryptedArtifactResult(
            plaintextSHA256: plainDigest,
            ciphertextSHA256: cipherDigest,
            plaintextBytes: plaintextBytes,
            ciphertextBytes: cipherBytes,
            chunkBytes: chunkBytes,
            wrappedKey: VaultKeyWrap(
                recipientCertificateSHA256: actualFingerprint,
                wrappedKeyBase64: wrapped.base64EncodedString()
            )
        )
        #else
        throw AgentError.unsupported("hardware vault encryption requires macOS CryptoKit + Security.framework")
        #endif
    }

    public func decrypt(
        ciphertext: URL,
        plaintext: URL,
        keyWrap: VaultKeyWrap,
        expectedCiphertextSHA256: String,
        expectedPlaintextSHA256: String
    ) throws {
        #if canImport(CryptoKit) && canImport(Security)
        guard keyWrap.algorithm == "rsa-oaep-sha256" else {
            throw AgentError.unsupported("unsupported vault key wrap: \(keyWrap.algorithm)")
        }
        let actualCipher = try Digest.sha256(file: ciphertext)
        guard Self.constantTimeEqualHex(actualCipher, expectedCiphertextSHA256) else {
            throw AgentError.trustFailure("ciphertext digest mismatch; refusing to unwrap or boot image")
        }

        let fingerprint = Self.normalizeFingerprint(keyWrap.recipientCertificateSHA256)
        let identity = try macIdentity(fingerprint: fingerprint)
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, let privateKey else {
            throw AgentError.authorizationRequired("PIV private key is unavailable; insert the configured YubiKey")
        }
        guard Self.isRSA(privateKey), SecKeyIsAlgorithmSupported(privateKey, .decrypt, .rsaEncryptionOAEPSHA256) else {
            throw AgentError.unsupported("configured PIV key does not support RSA-OAEP-SHA256 unwrap")
        }
        guard let wrapped = Data(base64Encoded: keyWrap.wrappedKeyBase64) else {
            throw AgentError.malformed("vault wrapped key is not valid base64")
        }

        print("Touch YubiKey to unlock genesis image…")
        var unwrapError: Unmanaged<CFError>?
        guard let keyCF = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, wrapped as CFData, &unwrapError) else {
            throw AgentError.authorizationRequired("YubiKey unwrap failed: \(Self.describe(unwrapError))")
        }
        let keyData = keyCF as Data
        guard keyData.count == 32 else { throw AgentError.trustFailure("unwrapped vault key has invalid length") }
        let symmetric = SymmetricKey(data: keyData)

        let input = try FileHandle(forReadingFrom: ciphertext)
        defer { try? input.close() }
        let headerSize = Self.magic.count + 4 + 4
        guard let header = try input.read(upToCount: headerSize), header.count == headerSize else {
            throw AgentError.malformed("vault object is truncated before header")
        }
        guard header.prefix(Self.magic.count) == Self.magic else { throw AgentError.malformed("not an agent vault object") }
        let version = Self.readUInt32(header, offset: Self.magic.count)
        guard version == Self.version else { throw AgentError.unsupported("unsupported vault object version: \(version)") }
        let chunkBytes = Self.readUInt32(header, offset: Self.magic.count + 4)
        guard chunkBytes >= 64 * 1024, chunkBytes <= 64 * 1024 * 1024 else { throw AgentError.malformed("invalid vault chunk size") }

        FileManager.default.createFile(atPath: plaintext.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: plaintext)
        defer { try? output.close() }

        var expectedIndex: UInt64 = 0
        var sawSentinel = false
        while true {
            guard let recordHeader = try input.read(upToCount: 12), !recordHeader.isEmpty else { break }
            guard recordHeader.count == 12 else { throw AgentError.malformed("vault object has a truncated record header") }
            let index = Self.readUInt64(recordHeader, offset: 0)
            let length = Self.readUInt32(recordHeader, offset: 8)
            if index == UInt64.max {
                guard length == 0 else { throw AgentError.malformed("vault sentinel has non-zero length") }
                sawSentinel = true
                let extra = try input.read(upToCount: 1) ?? Data()
                guard extra.isEmpty else { throw AgentError.malformed("vault object has trailing bytes") }
                break
            }
            guard index == expectedIndex else { throw AgentError.malformed("vault chunk sequence mismatch") }
            guard length > 28, length <= UInt32(chunkBytes) + 64 else { throw AgentError.malformed("vault chunk length is invalid") }
            guard let combined = try input.read(upToCount: Int(length)), combined.count == Int(length) else {
                throw AgentError.malformed("vault object has a truncated encrypted chunk")
            }
            let box = try AES.GCM.SealedBox(combined: combined)
            let clear = try AES.GCM.open(box, using: symmetric, authenticating: Self.aad(header: header, index: index))
            guard clear.count <= Int(chunkBytes) else { throw AgentError.malformed("decrypted vault chunk exceeds declared size") }
            try output.write(contentsOf: clear)
            expectedIndex &+= 1
        }
        guard sawSentinel else { throw AgentError.malformed("vault object ended without authenticated completion sentinel") }
        try output.synchronize()

        let actualPlain = try Digest.sha256(file: plaintext)
        guard Self.constantTimeEqualHex(actualPlain, expectedPlaintextSHA256) else {
            try? FileManager.default.removeItem(at: plaintext)
            throw AgentError.trustFailure("decrypted image digest mismatch; refusing to load template")
        }
        #else
        throw AgentError.unsupported("hardware vault decryption requires macOS CryptoKit + Security.framework")
        #endif
    }

    #if canImport(CryptoKit) && canImport(Security)
    private func macIdentity(fingerprint: String) throws -> SecIdentity {
        for identity in try macIdentities() {
            var certificate: SecCertificate?
            var privateKey: SecKey?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, let privateKey,
                  Self.hardwareTokenID(privateKey) != nil else { continue }
            if Self.certificateFingerprint(certificate) == fingerprint { return identity }
        }
        throw AgentError.authorizationRequired("no connected hardware-backed Keychain/PIV identity matches certificate SHA-256 \(fingerprint)")
    }

    private func macIdentities() throws -> [SecIdentity] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let result else {
            throw AgentError.trustFailure("Keychain identity query failed: \(status)")
        }
        if CFGetTypeID(result) == CFArrayGetTypeID() {
            return result as! [SecIdentity]
        }
        guard CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw AgentError.malformed("Keychain identity query returned an unexpected object type")
        }
        return [result as! SecIdentity]
    }

    private static func certificateFingerprint(_ certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    
private static func isRSA(_ key: SecKey) -> Bool {
        guard let cfAttrs = SecKeyCopyAttributes(key) else {
            return false
        }
        let attrs = cfAttrs as NSDictionary

        guard let raw = attrs[kSecAttrKeyType] else { return false }
        if let value = raw as? String {
            return value == (kSecAttrKeyTypeRSA as String)
        }
        return String(describing: raw) == String(describing: kSecAttrKeyTypeRSA)
    }

    
private static func hardwareTokenID(_ key: SecKey) -> String? {
        guard let cfAttrs = SecKeyCopyAttributes(key) else {
            return nil
        }
        let attrs = cfAttrs as NSDictionary

        guard let raw = attrs[kSecAttrTokenID] else { return nil }
        if let value = raw as? String { return value }
        return String(describing: raw)
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "unknown Security.framework error" }
        return String(describing: error.takeRetainedValue())
    }

    private static func aad(header: Data, index: UInt64) -> Data {
        var data = Data("agent-vault-chunk-v1".utf8)
        data.append(header)
        data.append(be(index))
        return data
    }

    private static func be(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
    }

    private static func be(_ value: UInt64) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: MemoryLayout<UInt64>.size)
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { raw in
            UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber else { throw AgentError.malformed("could not determine file size") }
        return size.uint64Value
    }

    private static func constantTimeEqualHex(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.lowercased().utf8)
        let b = Array(rhs.lowercased().utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
    #endif

    public static func normalizeFingerprint(_ raw: String) -> String {
        raw.lowercased().filter { $0.isHexDigit }
    }
}
