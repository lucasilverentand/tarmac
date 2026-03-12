import Foundation
import Security

struct JWTGenerator: Sendable {
    private let appId: String
    private let privateKeyData: Data

    init(appId: String, privateKeyData: Data) {
        self.appId = appId
        self.privateKeyData = privateKeyData
    }

    func generateJWT() throws -> String {
        let now = Date()
        let expiration = now.addingTimeInterval(600)  // 10 minutes max for GitHub

        let header = try base64URLEncode(json: [
            "alg": "RS256",
            "typ": "JWT",
        ])

        let payload = try base64URLEncode(json: [
            "iat": "\(Int(now.timeIntervalSince1970) - 60)",
            "exp": "\(Int(expiration.timeIntervalSince1970))",
            "iss": appId,
        ])

        let signingInput = "\(header).\(payload)"
        let signature = try sign(signingInput)

        return "\(signingInput).\(signature)"
    }

    private func sign(_ input: String) throws -> String {
        guard let inputData = input.data(using: .utf8) else {
            throw JWTError.encodingFailed
        }

        let privateKey = try loadPrivateKey()

        var error: Unmanaged<CFError>?
        guard
            let signedData = SecKeyCreateSignature(
                privateKey,
                .rsaSignatureMessagePKCS1v15SHA256,
                inputData as CFData,
                &error
            ) as Data?
        else {
            let cfError = error?.takeRetainedValue()
            throw JWTError.signingFailed(cfError?.localizedDescription ?? "Unknown error")
        }

        return signedData.base64URLEncodedString()
    }

    private func loadPrivateKey() throws -> SecKey {
        // Strip PEM headers and decode
        let pemString = String(data: privateKeyData, encoding: .utf8) ?? ""
        let base64String =
            pemString
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let keyData = Data(base64Encoded: base64String) else {
            throw JWTError.invalidPrivateKey
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            // Try PKCS#8 format by stripping the header
            if let pkcs1Key = try? extractPKCS1FromPKCS8(keyData) {
                var innerError: Unmanaged<CFError>?
                if let key = SecKeyCreateWithData(pkcs1Key as CFData, attributes as CFDictionary, &innerError) {
                    return key
                }
            }
            let cfError = error?.takeRetainedValue()
            throw JWTError.invalidPrivateKey
        }

        return key
    }

    private func extractPKCS1FromPKCS8(_ pkcs8Data: Data) throws -> Data {
        // PKCS#8 wraps PKCS#1 with an AlgorithmIdentifier header
        // The RSA PKCS#8 header is typically 26 bytes for 2048-bit keys
        let bytes = [UInt8](pkcs8Data)
        guard bytes.count > 26 else { throw JWTError.invalidPrivateKey }

        // Look for the inner SEQUENCE tag (0x30) that starts the PKCS#1 key
        for i in 20..<min(bytes.count, 30) {
            if bytes[i] == 0x04 {  // OCTET STRING tag wrapping the key
                let lengthByte = bytes[i + 1]
                let dataStart: Int
                if lengthByte & 0x80 == 0 {
                    dataStart = i + 2
                } else {
                    let numLengthBytes = Int(lengthByte & 0x7F)
                    dataStart = i + 2 + numLengthBytes
                }
                if dataStart < bytes.count {
                    return Data(bytes[dataStart...])
                }
            }
        }

        throw JWTError.invalidPrivateKey
    }

    private func base64URLEncode(json: [String: String]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.base64URLEncodedString()
    }
}

enum JWTError: Error, LocalizedError, Sendable {
    case encodingFailed
    case signingFailed(String)
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode JWT"
        case .signingFailed(let detail): "JWT signing failed: \(detail)"
        case .invalidPrivateKey: "Invalid private key format"
        }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
