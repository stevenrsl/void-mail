import Foundation

/// The servers of a mail host, and how its accounts sign in.
struct ProviderPreset: Equatable {
    var name: String
    var imap: ServerEndpoint
    var smtp: ServerEndpoint
    /// The ways this host accepts, the first one offered.
    var auths: [MailAuth]
    /// Where to make an app password, when that's the way in.
    var appPasswordHelp: String?
    /// The host is known: its servers don't need to be checked by hand.
    var isKnown: Bool

    var preferredAuth: MailAuth { auths.first ?? .password }
}

/// The servers of the usual hosts, by the domain of the address. Unknown domains get the common
/// guess (`imap.<domain>` / `smtp.<domain>`, TLS), shown for correction. A local table: nothing of
/// the address leaves the Mac to find its servers.
enum ProviderDirectory {
    static func preset(for address: String) -> ProviderPreset {
        let domain = address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        switch domain {
        case "icloud.com", "me.com", "mac.com":
            return ProviderPreset(name: "iCloud",
                                  imap: .init(host: "imap.mail.me.com", port: 993, security: .tls),
                                  smtp: .init(host: "smtp.mail.me.com", port: 587, security: .startTLS),
                                  auths: [.password],
                                  appPasswordHelp: "Un mot de passe pour app se crée sur account.apple.com → Connexion et sécurité → Mots de passe pour app.",
                                  isKnown: true)
        case "gmail.com", "googlemail.com":
            // OAuth would be offered first once Google's client ID is set (see CONCEPT.md).
            return ProviderPreset(name: "Gmail",
                                  imap: .init(host: "imap.gmail.com", port: 993, security: .tls),
                                  smtp: .init(host: "smtp.gmail.com", port: 465, security: .tls),
                                  auths: OAuthProvider.google.isConfigured ? [.oauth(.google), .password] : [.password],
                                  appPasswordHelp: "Avec la validation en deux étapes activée, un mot de passe d'application se crée sur myaccount.google.com/apppasswords.",
                                  isKnown: true)
        case "outlook.com", "outlook.fr", "hotmail.com", "hotmail.fr", "live.com", "live.fr", "msn.com":
            // Microsoft no longer lets IMAP in with a password on personal accounts: OAuth only.
            return ProviderPreset(name: "Outlook",
                                  imap: .init(host: "outlook.office365.com", port: 993, security: .tls),
                                  smtp: .init(host: "smtp.office365.com", port: 587, security: .startTLS),
                                  auths: [.oauth(.microsoft)],
                                  appPasswordHelp: nil,
                                  isKnown: true)
        case "fastmail.com", "fastmail.fm":
            return ProviderPreset(name: "Fastmail",
                                  imap: .init(host: "imap.fastmail.com", port: 993, security: .tls),
                                  smtp: .init(host: "smtp.fastmail.com", port: 465, security: .tls),
                                  auths: [.password],
                                  appPasswordHelp: "Un mot de passe d'application se crée dans Fastmail → Réglages → Confidentialité et sécurité.",
                                  isKnown: true)
        case "proton.me", "protonmail.com", "pm.me":
            return ProviderPreset(name: "Proton Mail Bridge",
                                  imap: .init(host: "127.0.0.1", port: 1143, security: .startTLS),
                                  smtp: .init(host: "127.0.0.1", port: 1025, security: .startTLS),
                                  auths: [.password],
                                  appPasswordHelp: "Proton Mail Bridge doit être ouvert ; le mot de passe est celui qu'il affiche pour cette adresse.",
                                  isKnown: true)
        default:
            let host = domain.isEmpty ? "" : domain
            return ProviderPreset(name: domain.isEmpty ? "Autre" : domain,
                                  imap: .init(host: host.isEmpty ? "" : "imap.\(host)", port: 993, security: .tls),
                                  smtp: .init(host: host.isEmpty ? "" : "smtp.\(host)", port: 465, security: .tls),
                                  auths: [.password, .oauth(.microsoft)],
                                  appPasswordHelp: nil,
                                  isKnown: false)
        }
    }

    /// Hosts that also serve addresses on one's own domain: their servers, offered in « Serveurs »
    /// when the domain isn't one of theirs (`hello@mondomaine.fr` at Proton, iCloud+, Fastmail,
    /// Microsoft 365).
    static let customDomainHosts: [ProviderPreset] = [
        preset(for: "x@proton.me"),
        preset(for: "x@icloud.com"),
        preset(for: "x@fastmail.com"),
        ProviderPreset(name: "Microsoft 365", imap: OAuthProvider.microsoft.imap, smtp: OAuthProvider.microsoft.smtp,
                       auths: [.oauth(.microsoft)], appPasswordHelp: nil, isKnown: true),
    ]

    /// The usual secure port for a security, to fill in when it changes.
    static func defaultPort(imap: Bool, security: ConnectionSecurity) -> Int {
        switch (imap, security) {
        case (true, .tls): 993
        case (true, _): 143
        case (false, .tls): 465
        case (false, _): 587
        }
    }
}
