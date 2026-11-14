import BandCredentials
import BandLogging
import BandProtocol
import CryptoKit
import Foundation

public struct MetaAuthError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The claim failed because the Meta session is expired or revoked: sign in again.
public struct MetaSessionInvalidError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// The Meta sign-in chain used by kinesis and air-gestures (`MetaAuth.swift`, `metaauth.rs`):
/// an anonymous tokens query, Meta's own sign-in page at auth.meta.com in a web view, a blob
/// decrypt, and the ar-genai exchange that yields the user session (universe "ar").
/// The password only ever goes to Meta's page.
public enum MetaAuth {
    // Meta's own app client identifiers (`APP|<id>|<token>`, the ones Meta's apps send). They name
    // the requesting app, not a person, but they stay out of the source: the build puts them in
    // Info.plist from META_FRL_CLIENT, META_AR_CLIENT and META_HW_CLIENT (.env, see .env.example).
    static var frlClient: String { get throws { try client("MetaFRLClient") } }
    static var arClient: String { get throws { try client("MetaARClient") } }
    static var hwClient: String { get throws { try client("MetaHWClient") } }

    static func client(_ key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, value.split(separator: "|").count == 3 else {
            throw MetaAuthError("This build has no Meta client tokens, so it can't claim a band. Set META_FRL_CLIENT, META_AR_CLIENT and META_HW_CLIENT in .env (see .env.example) and rebuild. Bands claimed elsewhere still import and connect.")
        }
        return value
    }

    /// The FRL client's app id, which Meta's sign-in page is opened for.
    static var appID: String? { (try? frlClient).flatMap { $0.split(separator: "|").dropFirst().first.map(String.init) } }
    static let tokensQueryURL = URL(string: "https://meta.graph.meta.com/webview_tokens_query")!
    static let blobsDecryptURL = URL(string: "https://meta.graph.meta.com/webview_blobs_decrypt")!
    static let loginURL = URL(string: "https://ar-genai.graph.meta.com/login")!
    static var authEntryBase: String? {
        appID.map { "https://auth.meta.com/?native_app_id=\($0)&source_app_id=\($0)&native_sso_etoken=" }
    }

    public struct SSOTokens: Sendable {
        public let nativeSSOToken: String
        let etoken: String
        public var authEntryURL: URL? { authEntryBase.flatMap { URL(string: $0 + etoken) } }
    }

    /// Step 1: the anonymous webview tokens query.
    public static func tokensQuery() async throws -> SSOTokens {
        let lsd = makeLSD()
        let json = try await post(tokensQueryURL, step: "tokens query",
                                  multipart: [("access_token", frlClient), ("lsd", lsd), ("jazoest", jazoest(lsd))])
        guard let native = json["native_sso_token"] as? String, !native.isEmpty,
              let etoken = json["native_sso_etoken"] as? String, !etoken.isEmpty else {
            throw MetaAuthError("Meta didn't return sign-in tokens. Try again.")
        }
        logInfo(.meta, "Tokens query succeeded; opening auth.meta.com")
        return SSOTokens(nativeSSOToken: native, etoken: etoken)
    }

    /// The login callback must present the first 16 hex digits of SHA-256(native token).
    static func expectedCallbackToken(_ nativeSSOToken: String) -> String {
        String(SHA256.hash(data: Data(nativeSSOToken.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Whether a navigation is the login's custom-scheme callback.
    public static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "fb-viewapp" || url.absoluteString.contains("frl_login")
    }

    /// The blob from a valid callback, or nil when the token doesn't match this sign-in.
    public static func blob(fromCallback url: URL, tokens: SSOTokens) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value, token.count == 16,
              let blob = items.first(where: { $0.name == "blob" })?.value, !blob.isEmpty else { return nil }
        let expected = expectedCallbackToken(tokens.nativeSSOToken)
        var difference: UInt8 = 0
        for (a, b) in zip(token.utf8, expected.utf8) { difference |= a ^ b }
        return difference == 0 ? blob : nil
    }

    /// Step 3: decrypt the login blob into the FRL access token.
    public static func decryptBlob(_ blob: String, tokens: SSOTokens) async throws -> String {
        let lsd = makeLSD()
        let json = try await post(blobsDecryptURL, step: "blob decrypt",
                                  multipart: [("blob", blob), ("request_token", tokens.nativeSSOToken), ("access_token", frlClient),
                                              ("lsd", lsd), ("jazoest", jazoest(lsd))])
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw MetaAuthError("Meta didn't confirm the sign-in. Try again.")
        }
        return token
    }

    /// Step 4: exchange the FRL token for the ar user session.
    public static func login(frlAccessToken: String) async throws -> MetaSession {
        let deviceID = UUID().uuidString
        let json = try await post(loginURL, step: "account session", form: [
            ("frl_access_token", frlAccessToken), ("logging_session_id", UUID().uuidString), ("format", "json"),
            ("device_id", deviceID), ("generate_session_cookies", "1"), ("generate_analytics_claim", "1"), ("method", "POST"),
        ], headers: ["Authorization": "OAuth " + arClient])
        let userID = (json["user_id"] as? String) ?? (json["user_id"] as? NSNumber)?.stringValue
        guard let token = json["access_token"] as? String, !token.isEmpty, let userID, !userID.isEmpty else {
            throw MetaAuthError("Meta didn't return an account session. Try again.")
        }
        logNotice(.meta, "Signed in to Meta (user id \(BandLog.mask(userID)))")
        return MetaSession(accessToken: token, userID: userID, deviceID: deviceID)
    }

    // MARK: encoding

    static func makeLSD() -> String { "S0." + String((0..<6).map { _ in Character(String(Int.random(in: 0...9))) }) }
    static func jazoest(_ lsd: String) -> String { "2" + String(lsd.unicodeScalars.reduce(0) { $0 + $1.value }) }

    static func multipartBody(_ fields: [(String, String)], boundary: String) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static let formSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func urlForm(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: formSafe) ?? $0.1)" }
            .joined(separator: "&").utf8)
    }

    // MARK: transport

    private static func post(_ url: URL, step: String, multipart fields: [(String, String)]) async throws -> [String: Any] {
        let boundary = "neuralplayground.form.\(UUID().uuidString)"
        return try await post(url, step: step, headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)",
                                                         "Accept": "application/json", "Origin": "https://auth.meta.com"],
                              body: multipartBody(fields, boundary: boundary))
    }

    private static func post(_ url: URL, step: String, form fields: [(String, String)], headers: [String: String]) async throws -> [String: Any] {
        var headers = headers
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Accept"] = "application/json"
        return try await post(url, step: step, headers: headers, body: urlForm(fields))
    }

    private static func post(_ url: URL, step: String, headers: [String: String], body: Data) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        logInfo(.meta, "POST \(url.host ?? "")\(url.path) (\(step))")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            logError(.meta, "\(step) couldn't reach Meta: \(BandLog.describe(error))")
            throw MetaAuthError("Couldn't reach Meta (\(error.localizedDescription)). Check the internet connection.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        logInfo(.meta, "\(step): HTTP \(status), \(data.count)B, keys \(json.map { Array($0.keys).sorted() } ?? [])")
        guard status == 200, let json else {
            throw MetaAuthError("Meta sign-in failed at \(step) (HTTP \(status)). Try again.")
        }
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int
            let subcode = error["error_subcode"] as? Int
            logError(.meta, "\(step) error code \(code.map(String.init) ?? "-") subcode \(subcode.map(String.init) ?? "-") type \(error["type"] as? String ?? "-")")
            throw MetaAuthError("Meta sign-in failed (code \(code.map(String.init) ?? "-"), subcode \(subcode.map(String.init) ?? "-")). Try again.")
        }
        return json
    }
}

/// The two ownership HTTP exchanges against the hardware graph. Receipts travel verbatim.
public struct MetaPairClient: Sendable {
    public struct Pending: Sendable { public let signature: [UInt8]; public let receipt: String }
    public struct Final: Sendable { public let signature: [UInt8]; public let receipt: String; public let devicePublicKey: [UInt8]? }

    static let host = "https://graph.facebook-hardware.com"
    let session: MetaSession

    public init(session: MetaSession) { self.session = session }

    static func additionalData(nonce: [UInt8], appPublicKey: [UInt8], secondaryCert: String) -> String {
        "{\"device_nonce\":\"\(Data(nonce).base64EncodedString())\",\"app_pubkey\":\"\(Data(appPublicKey).base64EncodedString())\",\"secondary_cert\":\"\(secondaryCert)\"}"
    }

    public func pairRequest(_ request: CeremonyPairRequest) async throws -> Pending {
        let fields = try [("access_token", MetaAuth.hwClient), ("user_access_token", session.accessToken),
                      ("user_token_universe", MetaSession.universe), ("pair_protocol_version", "3"),
                      ("device_cert", Data(request.identity.deviceCertificate).base64EncodedString()),
                      ("serial_number", request.identity.serial),
                      ("additional_data", Self.additionalData(nonce: request.nonce, appPublicKey: request.appPublicKey,
                                                              secondaryCert: Data(request.identity.secondaryCertificate).base64EncodedString()))]
        let json = try await execute("pair_request", fields)
        guard let receipt = json["pending_ownership_receipt"] as? String, !receipt.isEmpty,
              let signature = Data(base64Encoded: json["receipt_signature"] as? String ?? "") else {
            throw MetaAuthError("Meta's band claim service didn't return a receipt. Try again.")
        }
        return Pending(signature: [UInt8](signature), receipt: receipt)
    }

    public func pair(_ pair: CeremonyPair) async throws -> Final {
        let fields = try [("access_token", MetaAuth.hwClient), ("user_access_token", session.accessToken),
                      ("user_token_universe", MetaSession.universe), ("pair_protocol_version", "3"),
                      ("device_pending_ownership_receipt", pair.receipt),
                      ("device_pending_ownership_receipt_signature", Data(pair.signature).base64EncodedString())]
        let json = try await execute("pair", fields)
        guard let receipt = json["final_ownership_receipt"] as? String, !receipt.isEmpty,
              let signature = Data(base64Encoded: json["receipt_signature"] as? String ?? "") else {
            throw MetaAuthError("Meta's band claim service didn't return a final receipt. Try again.")
        }
        // The live server has omitted device_ec_public_key; the band's proof then stays unverified.
        let key = Self.deviceKey(json) ?? (receipt.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }).flatMap(Self.deviceKey)
        logInfo(.ownership, "Final receipt received (\(receipt.count) chars); band key from Meta: \(key.map { "\($0.count)B" } ?? "absent")")
        return Final(signature: [UInt8](signature), receipt: receipt, devicePublicKey: key)
    }

    private static func deviceKey(_ json: [String: Any]) -> [UInt8]? {
        guard let additional = json["additional_data"] as? [String: Any],
              let key = Data(base64Encoded: additional["device_ec_public_key"] as? String ?? ""), !key.isEmpty else { return nil }
        return [UInt8](key)
    }

    private func execute(_ route: String, _ fields: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(Self.host)/\(route)")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = MetaAuth.urlForm(fields)
        logInfo(.ownership, "POST graph.facebook-hardware.com/\(route)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            logError(.ownership, "\(route) unreachable: \(BandLog.describe(error))")
            throw MetaAuthError("Meta's band claim service couldn't be reached: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        logInfo(.ownership, "\(route): HTTP \(status), \(data.count)B, error code \((error?["code"] as? Int).map(String.init) ?? "none")")
        if status == 401 || status == 403 || (error?["code"] as? Int) == 190 {
            throw MetaSessionInvalidError(message: "Your Meta session expired. Sign in again to claim the band.")
        }
        guard status == 200, let json else { throw MetaAuthError("Meta's band claim service failed (HTTP \(status)). Try again.") }
        if let error {
            let message = error["message"] as? String
            logError(.ownership, "\(route) rejected: code \((error["code"] as? Int).map(String.init) ?? "-") \(message ?? "")")
            throw MetaAuthError("Meta's band claim service rejected the request (code \((error["code"] as? Int).map(String.init) ?? "-")). \(message ?? "")")
        }
        return json
    }
}
