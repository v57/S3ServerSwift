import Foundation
import Testing

@testable import S3ServerSwift

@Suite("SigV4 crypto and canonicalization")
struct CryptoAndCanonicalizationTests {
    @Test("hex decoding is strict and encoding is lowercase")
    func hex() {
        #expect(Hex.encode(Data([0, 15, 16, 255])) == "000f10ff")
        #expect(Hex.decode("000F10ff") == Data([0, 15, 16, 255]))
        #expect(Hex.decode("0") == nil)
        #expect(Hex.decode("0g") == nil)
    }

    @Test("hash and HMAC match published vectors")
    func hashes() {
        #expect(
            CryptoPrimitives.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            CryptoPrimitives.md5Hex(Data("abc".utf8))
                == "900150983cd24fb0d6963f7d28e17f72"
        )
        #expect(
            Hex.encode(
                CryptoPrimitives.hmacSHA256(
                    key: Data(repeating: 0x0b, count: 20),
                    string: "Hi There"
                )
            ) == "b0344c61d8db38535ca8afceaf0bf12b"
                + "881dc200c9833da726e9376c2e32cff7"
        )
    }

    @Test("AWS signing key derivation matches the IAM documentation vector")
    func signingKey() {
        let key = CryptoPrimitives.signingKey(
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            date: "20120215",
            region: "us-east-1",
            service: "iam"
        )
        #expect(
            Hex.encode(key)
                == "f4780e2d9f65fa895f9c67b32ce1baf0"
                + "b0d8a43505a000a1a9e090d414db404d"
        )
    }

    @Test("signature comparison rejects malformed hex and compares decoded bytes")
    func signatureComparison() {
        #expect(CryptoPrimitives.signaturesMatch(expectedHex: "aabb", providedHex: "AABB"))
        #expect(!CryptoPrimitives.signaturesMatch(expectedHex: "aabb", providedHex: "aabc"))
        #expect(!CryptoPrimitives.signaturesMatch(expectedHex: "aabb", providedHex: "aab"))
        #expect(!CryptoPrimitives.signaturesMatch(expectedHex: "aabb", providedHex: "zzzz"))
    }

    @Test("URI segments decode and re-encode using RFC 3986")
    func canonicalURI() throws {
        #expect(try SigV4Canonicalization.canonicalURI("") == "/")
        #expect(
            try SigV4Canonicalization.canonicalURI("/photos/%E2%98%83 !'()*")
                == "/photos/%E2%98%83%20%21%27%28%29%2A"
        )
        #expect(try SigV4Canonicalization.canonicalURI("//a//") == "//a//")
        #expect(throws: CanonicalizationError.invalidPercentEncoding) {
            try SigV4Canonicalization.canonicalURI("/bad%2")
        }
        #expect(throws: CanonicalizationError.invalidUTF8) {
            try SigV4Canonicalization.canonicalURI("/%FF")
        }
    }

    @Test("query canonicalization preserves duplicates and sorts encoded pairs")
    func canonicalQuery() throws {
        #expect(
            try SigV4Canonicalization.canonicalQuery(
                "z=last&a=two&a=one&space=a+b&unicode=%E2%98%83&empty"
            ) == "a=one&a=two&empty=&space=a%20b&unicode=%E2%98%83&z=last"
        )
        #expect(
            try SigV4Canonicalization.canonicalQuery(
                "X-Amz-Signature=deadbeef&a=1&X-Amz-Date=now",
                excluding: ["X-Amz-Signature"]
            ) == "X-Amz-Date=now&a=1"
        )
    }

    @Test("signed headers are normalized, validated, and serialized")
    func canonicalHeaders() throws {
        let signed = try SigV4Canonicalization.parseSignedHeaders(" Content-Type ; HOST ; X-Amz-Date ")
        #expect(signed == ["content-type", "host", "x-amz-date"])
        #expect(
            try SigV4Canonicalization.canonicalHeaders(
                headers: [
                    "Content-Type": "  text/plain \t charset=utf-8 ",
                    "X-AMZ-DATE": "20150830T123600Z",
                ],
                signedHeaders: signed,
                fallbackHost: "example.amazonaws.com"
            ) == """
            content-type:text/plain charset=utf-8
            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            """
        )
        #expect(throws: CanonicalizationError.missingHost) {
            try SigV4Canonicalization.parseSignedHeaders("content-type")
        }
        #expect(throws: CanonicalizationError.missingSignedHeader("x-missing")) {
            try SigV4Canonicalization.canonicalHeaders(
                headers: ["host": "example.com"],
                signedHeaders: ["host", "x-missing"]
            )
        }
    }

    @Test("timestamps and credential scopes parse deterministically in UTC")
    func datesAndScope() throws {
        let timestamp = try SigV4Dates.parseAWSTimestamp("20150830T123600Z")
        #expect(SigV4Dates.awsTimestamp(timestamp) == "20150830T123600Z")
        #expect(SigV4Dates.iso8601ListDate(timestamp) == "2015-08-30T12:36:00.000Z")
        #expect(SigV4Dates.httpLastModified(timestamp) == "Sun, 30 Aug 2015 12:36:00 GMT")
        #expect(throws: SigV4ParsingError.invalidTimestamp) {
            try SigV4Dates.parseAWSTimestamp("20150230T123600Z")
        }

        let scope = try CredentialScope.parse("AKID/20150830/us-east-1/s3/aws4_request")
        #expect(scope.accessKeyID == "AKID")
        #expect(scope.scope == "20150830/us-east-1/s3/aws4_request")
        #expect(throws: SigV4ParsingError.invalidCredentialTerminator) {
            try CredentialScope.parse("AKID/20150830/us-east-1/s3/not-request")
        }
    }
}
