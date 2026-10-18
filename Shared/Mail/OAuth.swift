import AuthenticationServices
import CryptoKit
import Foundation

/// The hosts whose accounts sign in on their own page rather than with a password. Ready for
/// Microsoft (Outlook.com, Hotmail, Microsoft 365), which no longer lets IMAP in with a password;
/// written for Google too, left off (see CONCEPT.md). A provider is offered once its client ID is
/// in Config/Info.plist; until then, its sign-in is shown greyed, with the reason.
enum OAuthProvider: String, Codable, CaseIterable, Identifiable {
    case microsoft, google
    var id: String { rawValue }

    var label: String {
        switch self {
        case .microsoft: "Microsoft"
        case .google: "Google"
        }
    }

    var clientID: String {
        let key = self == .microsoft ? "VoidMailMicrosoftClientID" : "VoidMailGoogleClientID"
        return (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    var isConfigured: Bool { !clientID.isEmpty }

    /// Why the sign-in can't be offered yet.
    var unconfiguredReason: String {
        switch self {
        case .microsoft:
            "La connexion Microsoft attend un identifiant d'application Azure (gratuit), à mettre dans Config/Info.plist → VoidMailMicrosoftClientID."
        case .google:
            "La connexion Google n'est pas activée : utilisez un mot de passe d'application."
        }
    }

    var authorizeURL: URL {
        switch self {
        case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        case .google: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        }
    }

    var tokenURL: URL {
        switch self {
        case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        case .google: URL(string: "https://oauth2.googleapis.com/token")!
        }
    }

    /// Reading and sending mail, and staying signed in (a refresh token).
    var scopes: [String] {
        switch self {
        case .microsoft: ["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send", "offline_access"]
        case .google: ["https://mail.google.com/"]
        }
    }

    /// Registered with the provider as the app's redirect URI; macOS hands it back to the sign-in
    /// sheet, not to the app.
    static let callbackScheme = "voidmail"
    static let redirectURI = "voidmail://oauth"

    /// The servers of the provider: an address on another domain (Microsoft 365) signing in with
    /// it uses them.
    var imap: ServerEndpoint {
        switch self {
        case .microsoft: .init(host: "outlook.office365.com", port: 993, security: .tls)
        case .google: .init(host: "imap.gmail.com", port: 993, security: .tls)
        }
    }

    var smtp: ServerEndpoint {
        switch self {
        case .microsoft: .init(host: "smtp.office365.com", port: 587, security: .startTLS)
        case .google: .init(host: "smtp.gmail.com", port: 465, security: .tls)
        }
    }
}

/// What the provider gives back: kept in the keychain, as JSON, under the account.
struct OAuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expires: Date

    /// A minute's margin: a token about to expire is refreshed before it is used.
    var isFresh: Bool { expires.timeIntervalSinceNow > 60 }
}

enum OAuthError: LocalizedError {
    case notConfigured(OAuthProvider)
    case cancelled
    case refused(String)
    case noRefreshToken

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider): provider.unconfiguredReason
        case .cancelled: "Connexion annulée."
        case .refused(let message): "Le fournisseur a refusé la connexion : \(message)"
        case .noRefreshToken: "La connexion a expiré : reconnectez le compte."
        }
    }
}

/// Sign-in with PKCE (no client secret: a desktop app can't keep one) in the system's sign-in
/// sheet, then tokens refreshed as needed. Nothing goes through a server of Void.
@MainActor
enum OAuthClient {
    /// Opens the provider's sign-in page; on success, the tokens are in the keychain.
    static func signIn(_ provider: OAuthProvider, address: String, account: UUID) async throws {
        guard provider.isConfigured else { throw OAuthError.notConfigured(provider) }
        let verifier = randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomURLSafe(bytes: 16)
        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: provider.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: OAuthProvider.redirectURI),
            .init(name: "scope", value: provider.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "login_hint", value: address),
        ] + (provider == .google ? [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")] : [])

        let callback = try await present(components.url!)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw OAuthError.refused(value("error_description") ?? error) }
        guard value("state") == state, let code = value("code") else { throw OAuthError.refused("réponse inattendue") }

        let tokens = try await requestTokens(provider, form: [
            "client_id": provider.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OAuthProvider.redirectURI,
            "code_verifier": verifier,
        ], previousRefreshToken: nil)
        try store(tokens, for: account)
    }

    /// A valid access token for the account, refreshed first if it is about to expire.
    static func accessToken(_ provider: OAuthProvider, account: UUID) async throws -> String {
        guard let data = Keychain.read(for: account, kind: .oauth),
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else { throw OAuthError.noRefreshToken }
        if tokens.isFresh { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else { throw OAuthError.noRefreshToken }
        var form = ["client_id": provider.clientID, "grant_type": "refresh_token", "refresh_token": refresh]
        if provider == .microsoft { form["scope"] = provider.scopes.joined(separator: " ") }
        let renewed = try await requestTokens(provider, form: form, previousRefreshToken: refresh)
        try store(renewed, for: account)
        return renewed.accessToken
    }

    private static func store(_ tokens: OAuthTokens, for account: UUID) throws {
        try Keychain.save(try JSONEncoder().encode(tokens), for: account, kind: .oauth)
    }

    /// The token endpoint, form-encoded. A refresh that brings no new refresh token keeps the old one.
    private static func requestTokens(_ provider: OAuthProvider, form: [String: String], previousRefreshToken: String?) async throws -> OAuthTokens {
        var request = URLRequest(url: provider.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else {
            throw OAuthError.refused(json["error_description"] as? String ?? json["error"] as? String ?? "réponse illisible")
        }
        let lifetime = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? String ?? "") ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: json["refresh_token"] as? String ?? previousRefreshToken,
                           expires: Date().addingTimeInterval(lifetime))
    }

    private static func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: OAuthProvider.callbackScheme) { callback, error in
                if let callback { continuation.resume(returning: callback); return }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.cancelled)
                }
            }
            session.presentationContextProvider = PresentationAnchor.shared
            // The provider's own cookies stay out: each account signs in on its own.
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }

    private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        static let shared = PresentationAnchor()
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            #if os(macOS)
            MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
            #else
            ASPresentationAnchor()
            #endif
        }
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
