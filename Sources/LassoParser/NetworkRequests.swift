import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Backs real Lasso's `include_url` (LassoGuide, "Network Requests with
/// Curl"). Implements the subset real corpus code actually needs — GET,
/// POST via `-postParams` (either a raw string/bytes body, or an array of
/// `.pair` values form-encoded per the docs' `trait_forEach` case),
/// `-sendMimeHeaders`, `-username`/`-password` (HTTP Basic),
/// `-timeout`/`-connectTimeout`, `-verifyPeer`, `-string`, `-noData`, and
/// `-retrieveMimeHeaders`. NOT implemented: `-getParams`, `-sslCert*`,
/// `-options` (raw `CURLOPT_*` passthrough), `-basicAuthOnly` (Basic auth is
/// always used when `-username`/`-password` are given, matching the
/// overwhelmingly common real-world case) — none of these appear in the
/// real corpus's one actual caller, `includes/efs_process.lasso`.
enum LassoIncludeURL {
    /// Test-only session override — when set, used instead of constructing
    /// a fresh session per call, so tests can inject a `URLProtocol`-backed
    /// mock session (matching `Perfect-FileMaker`'s own `MockURLProtocol`
    /// pattern) without this needing a dependency-injected parameter
    /// threaded through the fixed `LassoNativeFunction` signature.
    nonisolated(unsafe) static var testSessionOverride: URLSession?

    // MARK: - `-verifyPeer=false` (task #191)
    //
    // Darwin: InsecureTLSDelegate below does the real thing, unchanged.
    //
    // Linux: NOT implemented. swift-corelibs-foundation's URLSessionDelegate
    // doesn't expose `challenge.protectionSpace.serverTrust` at all — it's
    // typed `Any?` there and the real Darwin `SecTrust` bridging + Security
    // framework it needs don't exist on that platform (confirmed by direct
    // Linux build attempt: `serverTrust` reports "swift-corelibs-foundation
    // does not support methods of authentication that rely on the Darwin
    // Security framework", tracked as task #191). `perform(_:context:)`
    // below throws a clear, catchable `LassoRecoverableError` (code 3003)
    // when `-verifyPeer=false` is requested on Linux, rather than either
    // silently ignoring the flag (which would leave peer verification ON
    // while the caller explicitly asked for it OFF — a false claim of
    // having honored the request) or letting it fall through to a crash.
    //
    // What a real Linux implementation needs (for a future project, not
    // scoped here — no corpus evidence yet that any real caller needs
    // `-verifyPeer=false` off Darwin): swift-corelibs-foundation's
    // URLSession is libcurl-backed on Linux, and libcurl's own
    // CURLOPT_SSL_VERIFYPEER/CURLOPT_SSL_VERIFYHOST flags are the
    // equivalent mechanism — but URLSessionDelegate doesn't expose a
    // curl-easy-handle hook to set them per-request. Real options:
    // (a) a custom URLProtocol that shells out to libcurl directly
    //     (or a small C shim over libcurl) instead of going through
    //     URLSession's own networking stack, giving direct access to
    //     CURLOPT_SSL_VERIFYPEER;
    // (b) swift-nio-ssl's own TLS stack via a hand-rolled HTTP client
    //     instead of URLSession, with `NIOSSLContext`'s
    //     `.certificateVerification = .none` (the same mechanism
    //     `TLSContextManager`/`CertificateWatcher` already use elsewhere
    //     in this ecosystem for the *server* side);
    // (c) waiting for swift-corelibs-foundation to grow real Linux TLS
    //     trust APIs (tracked upstream, not on any committed timeline
    //     as of this writing).
    // (b) is probably the best fit for this codebase specifically, since
    // NIOSSL is already a first-class dependency via Perfect-NIO.
    #if canImport(Darwin)
    /// Accepts ANY server TLS certificate unconditionally when `-verifyPeer`
    /// is explicitly set to false — an explicit per-call opt-in for a known
    /// dev/test endpoint (e.g. a sandbox gateway or local self-signed
    /// service), never a default. Mirrors
    /// `Perfect-FileMaker-AdminAPI`'s `FMAdminInsecureTLSDelegate`.
    final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
    #endif

    /// Real `x-www-form-urlencoded`: only unreserved characters
    /// (alphanumeric, `-_.~`) stay literal, space becomes `+` (not `%20`),
    /// and a literal `+` in the input must itself be percent-encoded —
    /// distinct from `LassoEncoding.url`'s plain query-string percent-
    /// encoding (which leaves `+` untouched), so this stays local to
    /// POST-body encoding rather than shared with it.
    private static func formURLEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }

    static func perform(_ arguments: [EvaluatedArgument], context: inout LassoContext) async throws -> LassoValue {
        guard let urlString = arguments.first?.value.outputString, urlString.isEmpty == false,
              let url = URL(string: urlString) else {
            throw LassoRecoverableError(LassoErrorState(
                code: 3001,
                message: "Include_URL requires a valid URL.",
                kind: "network"
            ))
        }

        var request = URLRequest(url: url)

        if let postParams = arguments.firstValue(named: "postparams") {
            request.httpMethod = "POST"
            switch postParams {
            case let .array(values):
                let body = values.compactMap { value -> String? in
                    guard case let .pair(key, pairValue) = value else { return nil }
                    return "\(formURLEncode(key.outputString))=\(formURLEncode(pairValue.outputString))"
                }.joined(separator: "&")
                request.httpBody = Data(body.utf8)
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            case let .object(object) where object.typeName == LassoBytesValue.typeName:
                request.httpBody = Data(LassoBytesValue.rawBytes(from: object))
            default:
                request.httpBody = Data(postParams.outputString.utf8)
            }
        }

        if case let .array(headerPairs)? = arguments.firstValue(named: "sendmimeheaders") {
            for headerValue in headerPairs {
                guard case let .pair(name, value) = headerValue else { continue }
                request.setValue(value.outputString, forHTTPHeaderField: name.outputString)
            }
        }

        if let username = arguments.firstValue(named: "username")?.outputString {
            let password = arguments.firstValue(named: "password")?.outputString ?? ""
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        if let timeout = arguments.firstValue(named: "timeout")?.number
            ?? arguments.firstValue(named: "connecttimeout")?.number {
            request.timeoutInterval = timeout
        }

        let verifyPeer = arguments.firstValue(named: "verifypeer").map(\.isTruthy) ?? true
        let session: URLSession
        if let testSessionOverride {
            session = testSessionOverride
        } else if verifyPeer {
            session = .shared
        } else {
            #if canImport(Darwin)
            session = URLSession(configuration: .ephemeral, delegate: InsecureTLSDelegate(), delegateQueue: nil)
            #else
            // See the task #191 doc comment above InsecureTLSDelegate's
            // #if canImport(Darwin) block: not implemented on Linux yet.
            throw LassoRecoverableError(LassoErrorState(
                code: 3003,
                message: "Include_URL -verifyPeer=false is not supported on Linux.",
                kind: "network",
                detail: "TLS peer-verification bypass (task #191) has no Linux implementation yet — swift-corelibs-foundation exposes no server-trust API to build one against URLSession directly."
            ))
            #endif
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LassoRecoverableError(LassoErrorState(
                code: 3002,
                message: "Include_URL request failed.",
                kind: "network",
                detail: String(describing: error)
            ))
        }

        if let headerVarName = arguments.firstValue(named: "retrievemimeheaders")?.outputString,
           headerVarName.isEmpty == false,
           let httpResponse = response as? HTTPURLResponse {
            var headerValues: [String: LassoValue] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headerValues[String(describing: key).lowercased()] = .string(String(describing: value))
            }
            context.set(.map(headerValues), for: headerVarName, scope: .global)
        }

        if arguments.hasTruthyFlag("nodata") { return .void }
        if arguments.hasTruthyFlag("string") {
            return .string(String(decoding: data, as: UTF8.self))
        }
        return .object(LassoBytesValue.makeObject(rawBytes: Array(data)))
    }
}
