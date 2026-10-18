#if DEBUG
import AppKit

/// `-selfTest YES` (Debug builds): checks what can be checked without a server, prints each
/// result, and quits with the number of failures as exit status. `-network YES` adds real
/// connections, without signing in: IMAP in TLS (Gmail), IMAP upgraded by STARTTLS (Microsoft;
/// iCloud only opens 993), SMTP upgraded by STARTTLS (iCloud). Never touches the real
/// accounts, preferences or keychain (`DebugLaunch`).
@MainActor
enum SelfTest {
    private static var failures: [String] = []
    private static var count = 0

    static func run() {
        sasl()
        modifiedUTF7()
        imapParsing()
        mailboxRoles()
        providers()
        endpoints()
        accountsOnDisk()
        keychain()
        oauth()
        if UserDefaults.standard.bool(forKey: "network") {
            Task {
                await network()
                finish()
            }
            return
        }
        finish()
    }

    private static func finish() {
        print(failures.isEmpty ? "✓ \(count) vérifications réussies" : "✗ \(failures.count) échec(s) sur \(count) :\n" + failures.joined(separator: "\n"))
        exit(Int32(min(failures.count, 125)))
    }

    private static func network() async {
        print("Connexions réelles (sans identifiants)")
        do {
            let imap = try await IMAPClient.connect(to: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls))
            check(imap.capabilities.contains("AUTH=XOAUTH2") && imap.capabilities.contains("AUTH=PLAIN"), "IMAP en TLS : accueil et capacités (Gmail)")
            await imap.logout()
        } catch { check(false, "IMAP en TLS (Gmail) : \(error.localizedDescription)") }
        do {
            let imap = try await IMAPClient.connect(to: ServerEndpoint(host: "outlook.office365.com", port: 143, security: .startTLS))
            check(!imap.capabilities.contains("STARTTLS") && imap.transcript.contains { $0.contains("STARTTLS") }, "IMAP par STARTTLS : connexion chiffrée en cours de route (Microsoft)")
            await imap.logout()
        } catch { check(false, "IMAP par STARTTLS (Microsoft) : \(error.localizedDescription)") }
        do {
            let smtp = try await SMTPClient.connect(to: ServerEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS))
            check(smtp.extensions.contains { $0.hasPrefix("AUTH ") && $0.contains("PLAIN") }, "SMTP par STARTTLS : AUTH PLAIN proposé une fois chiffré (iCloud)")
            await smtp.quit()
        } catch { check(false, "SMTP par STARTTLS (iCloud) : \(error.localizedDescription)") }
        do {
            _ = try await IMAPClient.connect(to: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls))
                .authenticate(user: "void-mail-selftest@gmail.com", credential: .password("faux"))
            check(false, "un mauvais mot de passe est refusé")
        } catch MailError.authentication {
            check(true, "un mauvais mot de passe est refusé, avec un message clair")
        } catch { check(false, "un mauvais mot de passe : \(error.localizedDescription)") }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if condition() { print("  ✓ \(label)") } else { failures.append("  ✗ \(label)"); print("  ✗ \(label)") }
    }

    private static func sasl() {
        print("SASL")
        check(SASL.plain(user: "a@b.fr", password: "pw") == Data("\0a@b.fr\0pw".utf8).base64EncodedString(), "PLAIN : \\0utilisateur\\0mot de passe")
        let xoauth = String(data: Data(base64Encoded: SASL.xoauth2(user: "a@b.fr", token: "T"))!, encoding: .utf8)
        check(xoauth == "user=a@b.fr\u{1}auth=Bearer T\u{1}\u{1}", "XOAUTH2 : user, Bearer, deux ^A")
    }

    private static func modifiedUTF7() {
        print("Noms de boîtes (UTF-7 modifié)")
        check(ModifiedUTF7.decode("&AMk-l&AOk-ments envoy&AOk-s") == "Éléments envoyés", "décodage des accents")
        check(ModifiedUTF7.decode("Factures &- Devis") == "Factures & Devis", "&- donne &")
        check(ModifiedUTF7.decode("INBOX") == "INBOX", "ASCII inchangé")
        check(ModifiedUTF7.decode("&ZeVnLIqe-") == "日本語", "hors du plan latin")
        for name in ["Éléments envoyés", "Factures & Devis", "日本語", "Été/2026"] {
            check(ModifiedUTF7.decode(ModifiedUTF7.encode(name)) == name, "aller-retour « \(name) »")
        }
        check(ModifiedUTF7.encode("Éléments envoyés") == "&AMk-l&AOk-ments envoy&AOk-s", "encodage conforme")
    }

    private static func imapParsing() {
        print("Réponses IMAP")
        let sent = IMAPClient.parseList(#"* LIST (\HasNoChildren \Sent) "/" "Sent Messages""#)
        check(sent?.path == "Sent Messages" && sent?.delimiter == "/" && sent?.role == .sent, "LIST : nom entre guillemets, \\Sent")
        let atom = IMAPClient.parseList(#"* LIST (\HasNoChildren) "." INBOX.Factures"#)
        check(atom?.path == "INBOX.Factures" && atom?.name == "Factures" && atom?.depth == 1, "LIST : nom en atome, hiérarchie par « . »")
        let escaped = IMAPClient.parseList(#"* LIST () "/" "Dossier \"cité\"""#)
        check(escaped?.path == #"Dossier "cité""#, "LIST : guillemets échappés")
        let flat = IMAPClient.parseList(#"* LIST (\Noselect) NIL "[Gmail]""#)
        check(flat?.delimiter == nil && flat?.isSelectable == false, "LIST : NIL et \\Noselect")
        let utf7 = IMAPClient.parseList(#"* LIST (\Trash) "/" "&AMk-l&AOk-ments supprim&AOk-s""#)
        check(utf7?.path == "Éléments supprimés" && utf7?.role == .trash, "LIST : nom décodé, \\Trash")
        check(IMAPClient.parseList("* OK rien") == nil, "une autre réponse n'est pas une boîte")
        let caps = IMAPClient.capabilities(in: "* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] Prêt")
        check(caps == ["IMAP4REV1", "SASL-IR", "AUTH=PLAIN"], "capacités dans le message d'accueil")
        check(IMAPClient.capabilities(in: "* CAPABILITY IMAP4rev2 AUTH=XOAUTH2").contains("AUTH=XOAUTH2"), "réponse CAPABILITY")
        check(IMAPClient.quoted(#"pa"ss\word"#) == #""pa\"ss\\word""#, "chaîne entre guillemets échappée")
    }

    private static func mailboxRoles() {
        print("Rôle des boîtes")
        check(Mailbox(path: "inbox", delimiter: "/", attributes: []).role == .inbox, "INBOX quelle que soit la casse")
        check(Mailbox(path: "[Gmail]/Tous les messages", delimiter: "/", attributes: ["\\All"]).role == .archive, "\\All tient lieu d'archives")
        check(Mailbox.guessedAttributes(for: "Deleted Messages") == ["\\Trash"], "rôle deviné sans SPECIAL-USE")
        var account = MailAccount(name: "", address: "a@icloud.com", preset: ProviderDirectory.preset(for: "a@icloud.com"))
        account.mailboxes = ["Voyages", "Trash", "INBOX", "Sent", "Archive", "Drafts"]
            .map { Mailbox(path: $0, delimiter: "/", attributes: Mailbox.guessedAttributes(for: $0)) }
        check(account.sortedMailboxes.map(\.path) == ["INBOX", "Archive", "Sent", "Drafts", "Trash", "Voyages"], "ordre de la barre latérale")
    }

    private static func providers() {
        print("Hébergeurs")
        let icloud = ProviderDirectory.preset(for: "x@me.com")
        check(icloud.imap.host == "imap.mail.me.com" && icloud.smtp.security == .startTLS && icloud.preferredAuth == .password, "iCloud : mot de passe pour app, SMTP en STARTTLS")
        let gmail = ProviderDirectory.preset(for: "x@gmail.com")
        check(gmail.preferredAuth == .password && gmail.smtp.port == 465, "Gmail : mot de passe d'application tant que Google n'est pas configuré")
        let outlook = ProviderDirectory.preset(for: "x@hotmail.fr")
        check(outlook.auths == [.oauth(.microsoft)] && outlook.imap.host == "outlook.office365.com", "Outlook : OAuth Microsoft seulement")
        let proton = ProviderDirectory.preset(for: "x@proton.me")
        check(proton.imap.host == "127.0.0.1" && proton.imap.port == 1143, "Proton : Bridge sur ce Mac")
        let other = ProviderDirectory.preset(for: "hello@stevenrsl.eu")
        check(!other.isKnown && other.imap.host == "imap.stevenrsl.eu" && other.auths.contains(.oauth(.microsoft)), "domaine inconnu : serveurs devinés, Microsoft 365 possible")
        check(ProviderDirectory.defaultPort(imap: false, security: .startTLS) == 587, "port usuel selon le chiffrement")
        let hosts = ProviderDirectory.customDomainHosts.map(\.name)
        check(hosts == ["Proton Mail Bridge", "iCloud", "Fastmail", "Microsoft 365"], "hébergeurs proposés pour un domaine perso")
        check(ProviderDirectory.customDomainHosts.first?.smtp == ServerEndpoint(host: "127.0.0.1", port: 1025, security: .startTLS), "domaine perso chez Proton : SMTP de Bridge")
    }

    private static func endpoints() {
        print("Chiffrement")
        check(!ServerEndpoint(host: "imap.exemple.fr", port: 143, security: .none).isAllowed, "pas de connexion en clair vers Internet")
        check(ServerEndpoint(host: "127.0.0.1", port: 1143, security: .none).isAllowed, "en clair vers ce Mac seulement")
        check(LocalBridgeTrust.localHosts.contains("127.0.0.1") && !LocalBridgeTrust.localHosts.contains("127.0.0.2"), "certificat auto-signé accepté pour ce Mac seulement")
        check((try? MailStream(endpoint: ServerEndpoint(host: "imap.exemple.fr", port: 143, security: .none))) == nil, "la connexion refuse de s'ouvrir en clair")
    }

    private static func accountsOnDisk() {
        print("Comptes enregistrés")
        var account = MailAccount(name: "Steven", address: "s@outlook.com", preset: ProviderDirectory.preset(for: "s@outlook.com"))
        account.mailboxes = [Mailbox(path: "INBOX", delimiter: "/", attributes: ["\\HasNoChildren"])]
        let data = try? JSONEncoder().encode([account])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let back = data.flatMap { try? JSONDecoder().decode([MailAccount].self, from: $0) }
        check(back?.first == account, "aller-retour JSON, OAuth Microsoft compris")
        check(!json.contains("password\":\"") && !json.contains("token"), "aucun secret dans le fichier des comptes")
    }

    private static func keychain() {
        print("Trousseau (en mémoire pendant le test)")
        let id = UUID()
        try? Keychain.savePassword("secret", for: id)
        check(Keychain.password(for: id) == "secret", "mot de passe relu")
        Keychain.delete(for: id)
        check(Keychain.password(for: id) == nil, "retiré avec le compte")
    }

    private static func oauth() {
        print("OAuth")
        check(OAuthProvider.microsoft.scopes.contains("offline_access"), "Microsoft : jeton de rafraîchissement demandé")
        check(OAuthProvider.microsoft.smtp.host == "smtp.office365.com" && OAuthProvider.microsoft.smtp.security == .startTLS, "Microsoft : serveurs d'Office 365")
        check(OAuthProvider.microsoft.isConfigured == !OAuthProvider.microsoft.clientID.isEmpty, "proposé seulement avec un identifiant client")
        check(!OAuthTokens(accessToken: "a", refreshToken: "r", expires: Date().addingTimeInterval(30)).isFresh, "un jeton qui expire dans 30 s est rafraîchi")
        check(Data([0xFB, 0xFF]).base64URLEncoded == "-_8", "base64 URL sans remplissage (PKCE)")
    }
}
#endif
