import Foundation
import Security

/// Crypto for LAP pairing (P15-C1). Lutron pairing is a **certificate** handshake, not an app-key
/// string like Hue: the client generates an EC P-256 keypair, submits a PKCS#10 CSR over the 8083 TLS
/// socket during the button-press window, and the bridge signs it — returning a client certificate +
/// the bridge's CA. Those PEMs (cert + our private key + CA) are the credential stored in
/// `LutronConfig` and presented on every LEAP control connection as the TLS client identity.
///
/// This file is self-contained (`Security` only, no third-party crypto): a tiny ASN.1 DER encoder, a
/// P-256 CSR builder, a PKCS#8 EC private-key PEM writer/reader, and a `SecIdentity` assembler that
/// turns the stored PEMs back into a client identity for `Network.framework`.
enum LutronCrypto {

    // MARK: - Public entry points

    /// A freshly generated pairing keypair: the `SecKey` (kept in memory to sign the CSR) plus the
    /// PKCS#8 PEM we persist and the DER-encoded PKCS#10 CSR to submit to the bridge.
    struct PairingKeypair {
        let privateKey: SecKey
        let privateKeyPEM: String
        let csrPEM: String
    }

    /// Generate an EC P-256 keypair and build a signed CSR (CN=`commonName`).
    static func makePairingKeypair(commonName: String = "bacan") throws -> PairingKeypair {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw LutronError.credentialError("keygen: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        guard let pub = SecKeyCopyPublicKey(priv) else {
            throw LutronError.credentialError("no public key")
        }
        guard let pubData = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw LutronError.credentialError("pub export: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        guard let privData = SecKeyCopyExternalRepresentation(priv, &error) as Data? else {
            throw LutronError.credentialError("priv export: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        let csrDER = try buildCSR(commonName: commonName, publicKeyPoint: pubData, privateKey: priv)
        return PairingKeypair(
            privateKey: priv,
            privateKeyPEM: pem(privData.count >= 96 ? pkcs8(fromRawEC: privData) : privData, label: "PRIVATE KEY"),
            csrPEM: pem(csrDER, label: "CERTIFICATE REQUEST")
        )
    }

    /// Assemble a `SecIdentity` (client cert + private key) from the stored PEMs, for the LEAP control
    /// connection's TLS client authentication. Imports the cert + key into the keychain (idempotent by
    /// tag) and binds them into an identity.
    static func makeIdentity(certPEM: String, keyPEM: String) throws -> SecIdentity {
        guard let certDER = der(fromPEM: certPEM),
              let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw LutronError.credentialError("bad client certificate PEM")
        }
        guard let keyDER = der(fromPEM: keyPEM) else {
            throw LutronError.credentialError("bad client key PEM")
        }
        let rawEC = rawEC(fromPKCS8: keyDER) ?? keyDER
        var error: Unmanaged<CFError>?
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateWithData(rawEC as CFData, keyAttrs as CFDictionary, &error) else {
            throw LutronError.credentialError("key import: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        // Add cert + key to the keychain (ignore duplicate errors), then form the identity.
        let tag = "com.copoche.menere.lutron".data(using: .utf8)!
        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecAttrApplicationTag as String: tag,
        ]
        let keyStatus = SecItemAdd(addKey as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw LutronError.credentialError("keychain key add \(keyStatus)")
        }
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
        ]
        let certStatus = SecItemAdd(addCert as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw LutronError.credentialError("keychain cert add \(certStatus)")
        }

        // On iOS a SecIdentity can't be minted directly from a cert (that API is macOS-only); the
        // keychain forms it automatically once a matching private key + certificate are both present.
        // Query all identities and pick the one whose certificate DER matches ours.
        let wantedDER = SecCertificateCopyData(cert) as Data
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw LutronError.credentialError("identity query \(status)")
        }
        for identity in identities {
            var idCert: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &idCert) == errSecSuccess, let idCert else { continue }
            if (SecCertificateCopyData(idCert) as Data) == wantedDER { return identity }
        }
        throw LutronError.credentialError("identity not found after import")
    }

    // MARK: - PKCS#10 CSR

    private static func buildCSR(commonName: String, publicKeyPoint: Data, privateKey: SecKey) throws -> Data {
        // CertificationRequestInfo
        let version = asn1Integer(0)
        let subject = asn1Sequence(asn1Set(asn1Sequence(oidCommonName + asn1UTF8String(commonName))))
        let spki = subjectPublicKeyInfo(publicKeyPoint)
        let attributes = Data([0xA0, 0x00])   // [0] IMPLICIT SET OF Attribute — empty
        let cri = asn1Sequence(version + subject + spki + attributes)

        // Sign CRI with ecdsa-with-SHA256 (X9.62 DER signature).
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, cri as CFData, &error
        ) as Data? else {
            throw LutronError.credentialError("CSR sign: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        let sigAlg = asn1Sequence(oidEcdsaWithSHA256)
        let sigBitString = asn1BitString(sig)
        return asn1Sequence(cri + sigAlg + sigBitString)
    }

    private static func subjectPublicKeyInfo(_ point: Data) -> Data {
        let alg = asn1Sequence(oidEcPublicKey + oidPrime256v1)
        return asn1Sequence(alg + asn1BitString(point))
    }

    // MARK: - PKCS#8 wrap / unwrap for the EC private key (round-trips through our own storage)

    /// SecKey EC private export is the raw `04||X||Y||D` (byte 0x04 + 32+32 pub + 32 priv). Wrap it as a
    /// standard PKCS#8 PrivateKeyInfo so the stored PEM is `-----BEGIN PRIVATE KEY-----`.
    private static func pkcs8(fromRawEC raw: Data) -> Data {
        // raw = 0x04 || X(32) || Y(32) || D(32) → pub point = first 65 bytes, D = last 32.
        let pub = raw.prefix(65)
        let d = raw.suffix(32)
        // ECPrivateKey (SEC1): SEQ { INTEGER 1, OCTET STRING(d), [1] BIT STRING(pub) }
        let ecPrivate = asn1Sequence(
            asn1Integer(1)
                + asn1OctetString(Data(d))
                + asn1Explicit(1, asn1BitString(Data(pub)))
        )
        let alg = asn1Sequence(oidEcPublicKey + oidPrime256v1)
        return asn1Sequence(asn1Integer(0) + alg + asn1OctetString(ecPrivate))
    }

    /// Recover the raw `04||X||Y||D` representation from a PKCS#8 (or bare SEC1) EC private key DER, so
    /// `SecKeyCreateWithData` can rebuild the key. Best-effort structural walk of what we ourselves
    /// wrote; returns nil if the shape is unrecognized (caller falls back to using the DER as-is).
    private static func rawEC(fromPKCS8 der: Data) -> Data? {
        // Find the innermost OCTET STRING that holds the SEC1 ECPrivateKey, then pull INTEGER(d) and
        // the [1] BIT STRING(pub). This is a lenient scan tuned to our own `pkcs8(fromRawEC:)` output.
        guard let ec = firstSEC1(in: der) else { return nil }
        guard let d = ec.privateScalar, let pub = ec.publicPoint else { return nil }
        var out = Data()
        out.append(pub)          // 0x04||X||Y (65)
        out.append(d)            // D (32)
        return out
    }

    private struct SEC1Fields { let privateScalar: Data?; let publicPoint: Data? }

    private static func firstSEC1(in der: Data) -> SEC1Fields? {
        // Walk PKCS#8: SEQ { INT 0, SEQ(alg), OCTET STRING(sec1) }. Grab the LAST octet string's bytes
        // and parse the SEC1 inside.
        let bytes = [UInt8](der)
        var i = 0
        func readLen(_ idx: inout Int) -> Int? {
            guard idx < bytes.count else { return nil }
            let first = bytes[idx]; idx += 1
            if first & 0x80 == 0 { return Int(first) }
            let n = Int(first & 0x7f)
            guard n > 0, idx + n <= bytes.count else { return nil }
            var len = 0
            for _ in 0..<n { len = (len << 8) | Int(bytes[idx]); idx += 1 }
            return len
        }
        // Top SEQUENCE
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }
        i += 1
        guard readLen(&i) != nil else { return nil }
        // Scan TLVs at this level, remember the last OCTET STRING (0x04) payload.
        var sec1: [UInt8]?
        while i < bytes.count {
            let tag = bytes[i]; i += 1
            guard let len = readLen(&i), i + len <= bytes.count else { break }
            if tag == 0x04 { sec1 = Array(bytes[i..<i + len]) }
            i += len
        }
        guard let sec1 else { return nil }
        return parseSEC1(sec1)
    }

    private static func parseSEC1(_ bytes: [UInt8]) -> SEC1Fields? {
        var i = 0
        func readLen(_ idx: inout Int) -> Int? {
            guard idx < bytes.count else { return nil }
            let first = bytes[idx]; idx += 1
            if first & 0x80 == 0 { return Int(first) }
            let n = Int(first & 0x7f)
            guard n > 0, idx + n <= bytes.count else { return nil }
            var len = 0
            for _ in 0..<n { len = (len << 8) | Int(bytes[idx]); idx += 1 }
            return len
        }
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }   // SEQUENCE
        i += 1
        guard readLen(&i) != nil else { return nil }
        var priv: Data?
        var pub: Data?
        while i < bytes.count {
            let tag = bytes[i]; i += 1
            guard let len = readLen(&i), i + len <= bytes.count else { break }
            let payload = Array(bytes[i..<i + len])
            switch tag {
            case 0x04 where priv == nil:                 // OCTET STRING → private scalar
                priv = Data(payload)
            case 0xA1:                                    // [1] EXPLICIT BIT STRING(pub)
                // payload starts with an inner BIT STRING: 0x03 len 0x00 <point>
                if payload.count > 3, payload[0] == 0x03 {
                    var j = 1
                    // inner length
                    let l0 = payload[j]; j += 1
                    var innerLen = Int(l0)
                    if l0 & 0x80 != 0 {
                        let n = Int(l0 & 0x7f)
                        innerLen = 0
                        for _ in 0..<n { innerLen = (innerLen << 8) | Int(payload[j]); j += 1 }
                    }
                    _ = innerLen
                    // skip the "unused bits" byte
                    if j < payload.count, payload[j] == 0x00 { j += 1 }
                    pub = Data(payload[j...])
                }
            default:
                break
            }
            i += len
        }
        return SEC1Fields(privateScalar: priv, publicPoint: pub)
    }

    // MARK: - ASN.1 DER primitives

    private static func asn1Length(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var len = length
        var bytes: [UInt8] = []
        while len > 0 { bytes.insert(UInt8(len & 0xff), at: 0); len >>= 8 }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    private static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        out.append(asn1Length(value.count))
        out.append(value)
        return out
    }

    private static func asn1Sequence(_ value: Data) -> Data { tlv(0x30, value) }
    private static func asn1Set(_ value: Data) -> Data { tlv(0x31, value) }
    private static func asn1OctetString(_ value: Data) -> Data { tlv(0x04, value) }
    private static func asn1UTF8String(_ s: String) -> Data { tlv(0x0c, Data(s.utf8)) }
    private static func asn1Explicit(_ tag: UInt8, _ value: Data) -> Data { tlv(0xA0 | tag, value) }

    private static func asn1Integer(_ value: Int) -> Data {
        if value == 0 { return Data([0x02, 0x01, 0x00]) }
        var v = value
        var bytes: [UInt8] = []
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        if bytes.first! & 0x80 != 0 { bytes.insert(0x00, at: 0) }   // keep it positive
        return tlv(0x02, Data(bytes))
    }

    private static func asn1BitString(_ value: Data) -> Data {
        var v = Data([0x00])   // 0 unused bits
        v.append(value)
        return tlv(0x03, v)
    }

    // OIDs (pre-encoded as full OBJECT IDENTIFIER TLVs).
    private static let oidEcPublicKey = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    private static let oidPrime256v1 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    private static let oidEcdsaWithSHA256 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    private static let oidCommonName = Data([0x06, 0x03, 0x55, 0x04, 0x03])

    // MARK: - PEM

    static func pem(_ der: Data, label: String) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(b64)\n-----END \(label)-----\n"
    }

    static func der(fromPEM pem: String) -> Data? {
        let body = pem
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: body)
    }
}
