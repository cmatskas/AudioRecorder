import CryptoKit
import Foundation

/// Raw AWS credentials, independent of any SDK type, for request signing.
struct RawAWSCredentials: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
}

/// Builds SigV4-presigned URLs for Amazon Transcribe's streaming WebSocket
/// endpoint, per the documented `stream-transcription-websocket` scheme:
/// GET with all auth material in the query string, signed headers = host only,
/// payload hash of the empty string.
enum TranscribePresigner {
    struct Parameters {
        var languageCode = "en-US"
        var mediaEncoding = "pcm"
        var sampleRate = 16_000
        var enablePartialResultsStabilization = true
        var partialResultsStability = "high"
    }

    static func presignedURL(
        region: String,
        credentials: RawAWSCredentials,
        parameters: Parameters = Parameters(),
        date: Date = Date(),
        expiresSeconds: Int = 300
    ) -> URL {
        let service = "transcribe"
        let host = "transcribestreaming.\(region).amazonaws.com:8443"
        let path = "/stream-transcription-websocket"

        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        stampFormatter.timeZone = TimeZone(identifier: "UTC")
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        let amzDate = stampFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        var query: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(credentialScope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expiresSeconds)),
            ("X-Amz-SignedHeaders", "host"),
            ("language-code", parameters.languageCode),
            ("media-encoding", parameters.mediaEncoding),
            ("sample-rate", String(parameters.sampleRate)),
        ]
        if parameters.enablePartialResultsStabilization {
            query.append(("enable-partial-results-stabilization", "true"))
            query.append(("partial-results-stability", parameters.partialResultsStability))
        }
        if let token = credentials.sessionToken {
            query.append(("X-Amz-Security-Token", token))
        }

        let canonicalQuery = query
            .map { (uriEncode($0.0), uriEncode($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            "GET",
            path,
            canonicalQuery,
            "host:\(host)",
            "",
            "host",
            sha256Hex(Data()),
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var signingKey = hmac(
            key: Data("AWS4\(credentials.secretAccessKey)".utf8), data: Data(dateStamp.utf8)
        )
        for element in [region, service, "aws4_request"] {
            signingKey = hmac(key: signingKey, data: Data(element.utf8))
        }
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let urlString = "wss://\(host)\(path)?\(canonicalQuery)&X-Amz-Signature=\(signature)"
        guard let url = URL(string: urlString) else {
            preconditionFailure("presigned Transcribe URL was not a valid URL")
        }
        return url
    }

    // MARK: - Primitives

    /// RFC 3986 encoding as SigV4 requires: everything except unreserved
    /// characters is percent-encoded, uppercase hex.
    static func uriEncode(_ value: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".unicodeScalars)
        var encoded = ""
        for byte in Array(value.utf8) {
            let scalar = Unicode.Scalar(byte)
            if unreserved.contains(scalar) {
                encoded.unicodeScalars.append(scalar)
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
