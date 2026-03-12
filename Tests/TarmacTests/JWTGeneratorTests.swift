import Foundation
import Security
import Testing

@testable import Tarmac

@Suite("JWTGenerator")
struct JWTGeneratorTests {
    private let testKeyData: Data

    init() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }

        guard let keyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }

        // Wrap in PEM format
        let base64 = keyData.base64EncodedString(options: .lineLength64Characters)
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(base64)\n-----END RSA PRIVATE KEY-----"
        testKeyData = pem.data(using: .utf8)!
    }

    @Test("JWT has three dot-separated parts")
    func jwtStructure() throws {
        let generator = JWTGenerator(appId: "123456", privateKeyData: testKeyData)
        let jwt = try generator.generateJWT()
        let parts = jwt.split(separator: ".")
        #expect(parts.count == 3)
    }

    @Test("Header decodes to RS256 JWT")
    func headerContents() throws {
        let generator = JWTGenerator(appId: "123456", privateKeyData: testKeyData)
        let jwt = try generator.generateJWT()
        let headerPart = String(jwt.split(separator: ".")[0])

        // Restore base64 padding and standard encoding
        var base64 =
            headerPart
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        let data = try #require(Data(base64Encoded: base64))
        let header = try JSONSerialization.jsonObject(with: data) as! [String: String]

        #expect(header["alg"] == "RS256")
        #expect(header["typ"] == "JWT")
    }

    @Test("Payload contains iss, iat, exp")
    func payloadFields() throws {
        let appId = "987654"
        let generator = JWTGenerator(appId: appId, privateKeyData: testKeyData)
        let jwt = try generator.generateJWT()
        let payloadPart = String(jwt.split(separator: ".")[1])

        var base64 =
            payloadPart
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        let data = try #require(Data(base64Encoded: base64))
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: String]

        #expect(payload["iss"] == appId)
        #expect(payload["iat"] != nil)
        #expect(payload["exp"] != nil)
    }
}
