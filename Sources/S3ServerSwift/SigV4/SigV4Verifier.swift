import Foundation

struct SigV4AuthenticationError: Error, Equatable, Sendable {
    var code: String
    var message: String
    var status: Int = 403

    static func accessDenied(_ message: String) -> Self {
        Self(code: "AccessDenied", message: message)
    }
}

/// What a signed request's body must hash to, checked once the body is in
enum SigV4Payload: Sendable, Equatable {
    /// Presigned, or `UNSIGNED-PAYLOAD`: the signature doesn't cover the body
    case unsigned
    /// The lowercase hex SHA-256 the signature covers
    case sha256(String)

    func matches(_ body: Data) -> Bool {
        matches(hex: CryptoPrimitives.sha256Hex(body))
    }

    func matches(hex: String) -> Bool {
        switch self {
        case .unsigned: true
        case let .sha256(expected): expected == hex
        }
    }
}

struct SigV4Verifier: Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    var maximumTimeSkewSeconds: Int
    var now: @Sendable () -> Date

    init(
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        maximumTimeSkewSeconds: Int = 0,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.maximumTimeSkewSeconds = max(0, maximumTimeSkewSeconds)
        self.now = now
    }

    /// Checks a whole request, body included
    func verify(_ request: HTTPRequest) -> Result<Void, SigV4AuthenticationError> {
        verify(request.head).flatMap { payload in
            payload.matches(request.body) ? .success(()) : .failure(.accessDenied("payload hash mismatch"))
        }
    }

    /// Checks a request from its head alone, before its body is read: the signature covers the payload hash the
    /// request declares (`x-amz-content-sha256`), so a request that carries a body must declare one (or be presigned).
    /// The answer says what the body must hash to.
    func verify(_ head: HTTPRequestHead) -> Result<SigV4Payload, SigV4AuthenticationError> {
        do {
            return .success(try verifyThrowing(head))
        } catch let error as SigV4AuthenticationError {
            return .failure(error)
        } catch {
            return .failure(.accessDenied("Invalid signature"))
        }
    }

    private func verifyThrowing(_ request: HTTPRequestHead) throws -> SigV4Payload {
        let target = try parseTarget(request.target)
        let query = try queryValues(target.query)
        let presignedAlgorithm = query.firstValue(for: "X-Amz-Algorithm")
        let isPresigned = presignedAlgorithm != nil
        // As the reference: an upload that isn't presigned names its payload hash, which the signature covers
        if !isPresigned, request.method == "PUT" || request.method == "POST",
           header("x-amz-content-sha256", in: request.headers) == nil
        {
            throw SigV4AuthenticationError.accessDenied("Missing x-amz-content-sha256")
        }

        let fields: AuthenticationFields
        if isPresigned {
            guard presignedAlgorithm == "AWS4-HMAC-SHA256" else {
                throw SigV4AuthenticationError.accessDenied("Unsupported signature algorithm")
            }
            guard
                let credential = query.firstValue(for: "X-Amz-Credential"),
                let signedHeaders = query.firstValue(for: "X-Amz-SignedHeaders"),
                let signature = query.firstValue(for: "X-Amz-Signature"),
                let timestamp = query.firstValue(for: "X-Amz-Date")
            else {
                throw SigV4AuthenticationError.accessDenied("Missing presign fields")
            }
            guard
                let expirationValue = query.firstValue(for: "X-Amz-Expires"),
                let expiration = parseIntegerPrefix(expirationValue)
            else {
                throw SigV4AuthenticationError.accessDenied("Invalid presign expiration")
            }
            fields = AuthenticationFields(
                credential: credential,
                signedHeaders: signedHeaders,
                signature: signature,
                timestamp: timestamp,
                expiration: expiration
            )
        } else {
            guard let authorization = header("authorization", in: request.headers) else {
                throw SigV4AuthenticationError.accessDenied("Missing authorization")
            }
            let parsed = try parseAuthorizationHeader(authorization)
            guard let timestamp = header("x-amz-date", in: request.headers), !timestamp.isEmpty else {
                throw SigV4AuthenticationError.accessDenied("Missing x-amz-date")
            }
            fields = AuthenticationFields(
                credential: parsed.credential,
                signedHeaders: parsed.signedHeaders,
                signature: parsed.signature,
                timestamp: timestamp,
                expiration: nil
            )
        }

        let credential: CredentialScope
        do {
            credential = try CredentialScope.parse(fields.credential)
        } catch SigV4ParsingError.invalidCredentialTerminator {
            throw SigV4AuthenticationError.accessDenied("invalid credential terminator")
        } catch {
            throw SigV4AuthenticationError.accessDenied("invalid credential scope")
        }
        guard !credential.date.isEmpty, !credential.region.isEmpty else {
            throw SigV4AuthenticationError.accessDenied("Invalid credential scope")
        }
        guard credential.accessKeyID == accessKeyID else {
            throw SigV4AuthenticationError.accessDenied("Invalid access key")
        }
        guard credential.service == "s3" else {
            throw SigV4AuthenticationError.accessDenied("Invalid service")
        }

        if let sessionToken {
            let suppliedToken = header("x-amz-security-token", in: request.headers)
                ?? query.firstValue(for: "X-Amz-Security-Token")
            guard suppliedToken == sessionToken else {
                throw SigV4AuthenticationError.accessDenied("Invalid session token")
            }
        }

        let requestDate: Date
        do {
            requestDate = try SigV4Dates.parseAWSTimestamp(fields.timestamp)
        } catch {
            throw SigV4AuthenticationError.accessDenied("invalid x-amz-date")
        }
        guard credential.date == String(fields.timestamp.prefix(8)) else {
            throw SigV4AuthenticationError.accessDenied("Credential date mismatch")
        }

        if let expiration = fields.expiration {
            guard now().timeIntervalSince(requestDate) <= Double(expiration) else {
                throw SigV4AuthenticationError.accessDenied("Presigned URL expired")
            }
        } else if maximumTimeSkewSeconds > 0,
                  abs(now().timeIntervalSince(requestDate)) > Double(maximumTimeSkewSeconds)
        {
            throw SigV4AuthenticationError(
                code: "RequestTimeTooSkewed",
                message: "Request time too skewed"
            )
        }

        let signedHeaders: [String]
        do {
            signedHeaders = try SigV4Canonicalization.parseSignedHeaders(fields.signedHeaders)
        } catch CanonicalizationError.emptySignedHeaders {
            throw SigV4AuthenticationError.accessDenied("Missing signed headers")
        } catch CanonicalizationError.missingHost {
            throw SigV4AuthenticationError.accessDenied("Signed headers must include host")
        } catch {
            throw SigV4AuthenticationError.accessDenied("Invalid signed headers")
        }

        let canonicalHeaders: String
        do {
            canonicalHeaders = try SigV4Canonicalization.canonicalHeaders(
                headers: request.headers,
                signedHeaders: signedHeaders,
                fallbackHost: header("host", in: request.headers)
            )
        } catch CanonicalizationError.missingSignedHeader {
            throw SigV4AuthenticationError.accessDenied("Signed header missing")
        } catch {
            throw SigV4AuthenticationError.accessDenied("Invalid signed headers")
        }

        let canonicalURI: String
        let canonicalQuery: String
        do {
            canonicalURI = try SigV4Canonicalization.canonicalURI(target.path)
            canonicalQuery = try SigV4Canonicalization.canonicalQuery(
                target.query,
                excluding: isPresigned ? ["X-Amz-Signature"] : []
            )
        } catch {
            throw SigV4AuthenticationError.accessDenied("invalid path encoding")
        }

        let payloadHash: String
        let payload: SigV4Payload
        if isPresigned {
            payloadHash = "UNSIGNED-PAYLOAD"
            payload = .unsigned
        } else if let suppliedHash = header("x-amz-content-sha256", in: request.headers) {
            if suppliedHash == "UNSIGNED-PAYLOAD"
                || suppliedHash == "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
            {
                payloadHash = suppliedHash
                payload = .unsigned
            } else {
                payloadHash = suppliedHash.lowercased()
                payload = .sha256(payloadHash)
            }
        } else if request.contentLength == 0, request.method != "PUT", request.method != "POST" {
            // Without a declared hash the signature covers the empty body's
            payloadHash = CryptoPrimitives.sha256Hex(Data())
            payload = .sha256(payloadHash)
        } else {
            throw SigV4AuthenticationError.accessDenied("Missing x-amz-content-sha256")
        }

        let canonicalRequest = [
            request.method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders.joined(separator: ";"),
            payloadHash,
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            fields.timestamp,
            credential.scope,
            CryptoPrimitives.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")
        let signingKey = CryptoPrimitives.signingKey(
            secret: secretAccessKey,
            date: credential.date,
            region: credential.region,
            service: credential.service
        )
        let expected = Hex.encode(CryptoPrimitives.hmacSHA256(key: signingKey, string: stringToSign))
        guard CryptoPrimitives.signaturesMatch(
            expectedHex: expected,
            providedHex: fields.signature.lowercased()
        ) else {
            throw SigV4AuthenticationError.accessDenied("Signature mismatch")
        }
        return payload
    }

    private func parseAuthorizationHeader(
        _ value: String
    ) throws -> (credential: String, signedHeaders: String, signature: String) {
        let scheme = "AWS4-HMAC-SHA256 "
        guard value.hasPrefix(scheme) else {
            throw SigV4AuthenticationError.accessDenied("unsupported authorization scheme")
        }
        var parameters = [String: String]()
        for part in value.dropFirst(scheme.count).split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            parameters[String(trimmed[..<separator])] = String(trimmed[trimmed.index(after: separator)...])
        }
        guard
            let credential = parameters["Credential"], !credential.isEmpty,
            let signedHeaders = parameters["SignedHeaders"], !signedHeaders.isEmpty,
            let signature = parameters["Signature"], !signature.isEmpty
        else {
            throw SigV4AuthenticationError.accessDenied("missing authorization fields")
        }
        return (credential, signedHeaders, signature)
    }

    private func parseTarget(_ value: String) throws -> (path: String, query: String?) {
        let parts = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = parts.first, !path.isEmpty else {
            throw SigV4AuthenticationError.accessDenied("invalid path encoding")
        }
        return (String(path), parts.count == 2 ? String(parts[1]) : nil)
    }

    private func queryValues(_ rawQuery: String?) throws -> [(String, String)] {
        guard let rawQuery, !rawQuery.isEmpty else { return [] }
        return try rawQuery.split(separator: "&", omittingEmptySubsequences: false).map { pair in
            let separator = pair.firstIndex(of: "=")
            let rawKey = separator.map { pair[..<$0] } ?? pair[...]
            let rawValue = separator.map { pair[pair.index(after: $0)...] } ?? Substring()
            return (
                try SigV4Canonicalization.percentDecode(rawKey, plusAsSpace: true),
                try SigV4Canonicalization.percentDecode(rawValue, plusAsSpace: true)
            )
        }
    }

    private func parseIntegerPrefix(_ value: String) -> Int? {
        let trimmed = value.drop(while: \.isWhitespace)
        let sign = trimmed.first == "-" || trimmed.first == "+" ? String(trimmed.prefix(1)) : ""
        let digits = trimmed.dropFirst(sign.isEmpty ? 0 : 1).prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(sign + digits)
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private struct AuthenticationFields {
    var credential: String
    var signedHeaders: String
    var signature: String
    var timestamp: String
    var expiration: Int?
}

private extension Array where Element == (String, String) {
    func firstValue(for name: String) -> String? {
        first { $0.0 == name }?.1
    }
}
