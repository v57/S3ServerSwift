import Foundation
import Testing

@testable import S3ServerSwift

@Suite("SigV4 verifier")
struct SigV4VerifierTests {
    private let accessKey = "AKIDEXAMPLE"
    private let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    private let timestamp = "20150830T123600Z"
    private let requestDate = try! SigV4Dates.parseAWSTimestamp("20150830T123600Z")

    @Test("valid header authentication and supported payload markers")
    func validHeaderAuthentication() {
        let verifier = makeVerifier()
        let body = Data("hello".utf8)
        let digest = CryptoPrimitives.sha256Hex(body)
        #expect(verifier.verify(headerRequest(body: body, payloadHash: digest)).isSuccess)
        #expect(verifier.verify(headerRequest(body: body, payloadHash: "UNSIGNED-PAYLOAD")).isSuccess)
        #expect(
            verifier.verify(
                headerRequest(body: body, payloadHash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD")
            ).isSuccess
        )
    }

    @Test("valid presigned authentication excludes the signature query")
    func validPresignedAuthentication() {
        let verifier = makeVerifier(now: requestDate.addingTimeInterval(59))
        #expect(verifier.verify(presignedRequest(expires: 60)).isSuccess)
    }

    @Test("invalid credentials, service, signature, and payload are rejected")
    func invalidCredentialsAndPayload() {
        let verifier = makeVerifier()

        #expect(failure(verifier.verify(headerRequest(accessKey: "WRONG"))).message == "Invalid access key")
        #expect(failure(verifier.verify(headerRequest(service: "execute-api"))).message == "Invalid service")

        var badSignature = headerRequest()
        badSignature.headers["authorization"] = badSignature.headers["authorization"]?
            .replacingOccurrences(of: "Signature=", with: "Signature=00")
        #expect(failure(verifier.verify(badSignature)).message == "Signature mismatch")

        let mismatched = headerRequest(body: Data("changed".utf8), payloadHash: CryptoPrimitives.sha256Hex(Data()))
        #expect(failure(verifier.verify(mismatched)).message == "payload hash mismatch")
    }

    @Test("authorization fields and signed headers are required")
    func malformedAuthorization() {
        let verifier = makeVerifier()
        var request = headerRequest()
        request.headers.removeValue(forKey: "authorization")
        #expect(failure(verifier.verify(request)).message == "Missing authorization")

        request = headerRequest()
        request.headers["authorization"] = "Basic abc"
        #expect(failure(verifier.verify(request)).message == "unsupported authorization scheme")

        request = headerRequest(signedHeaders: "x-amz-date")
        #expect(failure(verifier.verify(request)).message == "Signed headers must include host")

        request = headerRequest(signedHeaders: "host;x-extra")
        #expect(failure(verifier.verify(request)).message == "Signed header missing")
    }

    @Test("session tokens are enforced only when configured")
    func sessionTokens() {
        let required = makeVerifier(sessionToken: "TOKEN")
        #expect(failure(required.verify(headerRequest())).message == "Invalid session token")
        #expect(required.verify(headerRequest(token: "TOKEN")).isSuccess)
        #expect(makeVerifier().verify(headerRequest(token: "unexpected")).isSuccess)

        let presigned = presignedRequest(token: "TOKEN")
        #expect(required.verify(presigned).isSuccess)
    }

    @Test("expiration, clock skew, and credential dates follow reference ordering")
    func timeControls() {
        let expired = makeVerifier(now: requestDate.addingTimeInterval(61))
        #expect(failure(expired.verify(presignedRequest(expires: 60))).message == "Presigned URL expired")

        let skewed = makeVerifier(maximumSkew: 30, now: requestDate.addingTimeInterval(31))
        let error = failure(skewed.verify(headerRequest()))
        #expect(error.code == "RequestTimeTooSkewed")

        let unlimited = makeVerifier(maximumSkew: 0, now: requestDate.addingTimeInterval(10_000))
        #expect(unlimited.verify(headerRequest()).isSuccess)

        #expect(
            failure(makeVerifier().verify(headerRequest(credentialDate: "20150829"))).message
                == "Credential date mismatch"
        )
    }

    @Test("presigned requests validate algorithm and required fields")
    func invalidPresignedFields() {
        let verifier = makeVerifier()
        var unsupported = presignedRequest()
        unsupported.target = unsupported.target.replacingOccurrences(
            of: "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            with: "X-Amz-Algorithm=OTHER"
        )
        #expect(failure(verifier.verify(unsupported)).message == "Unsupported signature algorithm")

        var missingSignature = presignedRequest()
        missingSignature.target = missingSignature.target.replacingOccurrences(
            of: "&X-Amz-Signature=" + queryValue("X-Amz-Signature", in: missingSignature.target)!,
            with: ""
        )
        #expect(failure(verifier.verify(missingSignature)).message == "Missing presign fields")
    }

    private func makeVerifier(
        sessionToken: String? = nil,
        maximumSkew: Int = 0,
        now: Date? = nil
    ) -> SigV4Verifier {
        let current = now ?? requestDate
        return SigV4Verifier(
            accessKeyID: accessKey,
            secretAccessKey: secret,
            sessionToken: sessionToken,
            maximumTimeSkewSeconds: maximumSkew,
            now: { current }
        )
    }

    private func headerRequest(
        body: Data = Data(),
        payloadHash: String? = nil,
        accessKey: String? = nil,
        service: String = "s3",
        credentialDate: String = "20150830",
        signedHeaders: String = "host;x-amz-content-sha256;x-amz-date",
        token: String? = nil
    ) -> HTTPRequest {
        let hash = payloadHash ?? CryptoPrimitives.sha256Hex(body)
        var headers = [
            "host": "examplebucket.s3.amazonaws.com",
            "x-amz-date": timestamp,
            "x-amz-content-sha256": hash,
        ]
        if let token {
            headers["x-amz-security-token"] = token
        }
        let credential = "\(accessKey ?? self.accessKey)/\(credentialDate)/us-east-1/\(service)/aws4_request"
        var signingHeaders = headers
        for name in signedHeaders.split(separator: ";").map(String.init) where signingHeaders[name] == nil {
            signingHeaders[name] = "fixture"
        }
        let signature = sign(
            method: "GET",
            target: "/test.txt",
            headers: signingHeaders,
            signedHeaders: signedHeaders,
            payloadHash: hash,
            credential: credential
        )
        headers["authorization"] =
            "AWS4-HMAC-SHA256 Credential=\(credential), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return HTTPRequest(method: "GET", target: "/test.txt", headers: headers, body: body)
    }

    private func presignedRequest(expires: Int = 60, token: String? = nil) -> HTTPRequest {
        let credential = "\(accessKey)/20150830/us-east-1/s3/aws4_request"
        var query = [
            "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "X-Amz-Credential=\(SigV4Canonicalization.encodeRFC3986(credential))",
            "X-Amz-Date=\(timestamp)",
            "X-Amz-Expires=\(expires)",
            "X-Amz-SignedHeaders=host",
            "partNumber=2",
            "partNumber=1",
        ]
        if let token {
            query.append("X-Amz-Security-Token=\(SigV4Canonicalization.encodeRFC3986(token))")
        }
        let unsignedTarget = "/test.txt?\(query.joined(separator: "&"))"
        let headers = ["host": "examplebucket.s3.amazonaws.com"]
        let signature = sign(
            method: "GET",
            target: unsignedTarget,
            headers: headers,
            signedHeaders: "host",
            payloadHash: "UNSIGNED-PAYLOAD",
            credential: credential
        )
        return HTTPRequest(
            method: "GET",
            target: "\(unsignedTarget)&X-Amz-Signature=\(signature)",
            headers: headers,
            body: Data()
        )
    }

    private func sign(
        method: String,
        target: String,
        headers: [String: String],
        signedHeaders: String,
        payloadHash: String,
        credential: String
    ) -> String {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let query = parts.count == 2 ? String(parts[1]) : nil
        let names = signedHeaders.split(separator: ";").map(String.init)
        let canonicalHeaders = try! SigV4Canonicalization.canonicalHeaders(
            headers: headers,
            signedHeaders: names
        )
        let canonicalRequest = [
            method,
            try! SigV4Canonicalization.canonicalURI(path),
            try! SigV4Canonicalization.canonicalQuery(query, excluding: ["X-Amz-Signature"]),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = try! CredentialScope.parse(credential)
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope.scope,
            CryptoPrimitives.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")
        return Hex.encode(
            CryptoPrimitives.hmacSHA256(
                key: CryptoPrimitives.signingKey(
                    secret: secret,
                    date: scope.date,
                    region: scope.region,
                    service: scope.service
                ),
                string: stringToSign
            )
        )
    }

    private func failure(
        _ result: Result<Void, SigV4AuthenticationError>
    ) -> SigV4AuthenticationError {
        guard case let .failure(error) = result else {
            Issue.record("Expected authentication failure")
            return .accessDenied("unexpected success")
        }
        return error
    }

    private func queryValue(_ key: String, in target: String) -> String? {
        target.split(separator: "?", maxSplits: 1).last?
            .split(separator: "&")
            .first { $0.hasPrefix("\(key)=") }?
            .split(separator: "=", maxSplits: 1)
            .last
            .map(String.init)
    }
}

private extension Result where Success == Void, Failure == SigV4AuthenticationError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
