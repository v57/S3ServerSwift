import CryptoKit
import Foundation

enum Hex {
    static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2), value.unicodeScalars.allSatisfy(isHexDigit) else {
            return nil
        }

        var result = Data()
        result.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            true
        default:
            false
        }
    }
}

enum CryptoPrimitives {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256(_ string: String) -> Data {
        sha256(Data(string.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        Hex.encode(sha256(data))
    }

    static func sha256Hex(_ string: String) -> String {
        Hex.encode(sha256(string))
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hmacSHA256(key: Data, string: String) -> Data {
        hmacSHA256(key: key, data: Data(string.utf8))
    }

    static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        let dateKey = hmacSHA256(key: Data("AWS4\(secret)".utf8), string: date)
        let regionKey = hmacSHA256(key: dateKey, string: region)
        let serviceKey = hmacSHA256(key: regionKey, string: service)
        return hmacSHA256(key: serviceKey, string: "aws4_request")
    }

    static func md5Hex(_ data: Data) -> String {
        Hex.encode(Insecure.MD5.hash(data: data))
    }

    static func signaturesMatch(expectedHex: String, providedHex: String) -> Bool {
        guard
            let expected = Hex.decode(expectedHex),
            let provided = Hex.decode(providedHex),
            expected.count == provided.count
        else {
            return false
        }

        var difference: UInt8 = 0
        for (left, right) in zip(expected, provided) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

/// SHA-256 of a body that comes in pieces
struct SHA256Hasher {
    private var hash = SHA256()

    mutating func update(_ data: Data) {
        hash.update(data: data)
    }

    func finalizeHex() -> String {
        Hex.encode(hash.finalize())
    }
}
