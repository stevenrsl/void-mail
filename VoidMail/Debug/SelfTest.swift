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
        imapValues()
        mime()
        dates()
        htmlPolicy()
        Task {
            await cacheChecks()
            afterOffline()
        }
    }

    private static func afterOffline() {
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

    private static func imapValues() {
        print("Réponses FETCH")
        let header = Data("* 3 FETCH (UID 42 FLAGS (\\Seen \\Flagged) INTERNALDATE \"17-Oct-2026 09:30:00 +0200\" RFC822.SIZE 2048 ENVELOPE (\"Fri, 17 Oct 2026 09:29:58 +0200\" {12}\r\n".utf8)
        let literal = Data("Caf\u{E9} cr\u{E8}me".utf8).prefix(12)
        var line = IMAPLine(data: header)
        line.data.removeLast(2)
        line.literalStarts.insert(line.data.count)
        line.data.append(literal)
        line.data.append(Data(" ((\"=?utf-8?Q?Camille_Moreau?=\" NIL \"camille\" \"exemple.fr\")) NIL NIL ((NIL NIL \"steven\" \"icloud.com\")) NIL NIL NIL \"<a@b>\"))".utf8))
        let envelope = MessageEnvelope(fetch: line)
        check(envelope?.uid == 42 && envelope?.flags == ["\\Seen", "\\Flagged"] && envelope?.size == 2048, "UID, drapeaux, taille")
        check(envelope?.subject == "Café crème", "objet en littéral {n}, octets UTF-8")
        check(envelope?.from.first == MailAddress(name: "Camille Moreau", address: "camille@exemple.fr"), "expéditeur, nom encodé décodé")
        check(envelope?.to.first?.address == "steven@icloud.com" && envelope?.messageID == "<a@b>", "destinataire, Message-ID")
        check(envelope?.date == MessageEnvelope.internalDate("17-Oct-2026 09:30:00 +0200"), "date d'arrivée du serveur")
        let body = IMAPLine("* 1 FETCH (UID 7 BODY[] NIL)").values
        check(body.count == 4 && body[3].pairs["BODY[]"] == .nilValue, "BODY[] reconnu comme une clé, NIL")
        check(IMAPLine("* 1 FETCH (BODY[HEADER.FIELDS (DATE FROM)] \"x\")").values[3].pairs.keys.contains("BODY[HEADER.FIELDS (DATE FROM)]"), "crochets avec espaces dans un atome")
        check(IMAPClient.code("UIDVALIDITY", in: "* OK [UIDVALIDITY 3857529045] UIDs valid") == 3857529045, "UIDVALIDITY")
    }

    private static func mime() {
        print("MIME")
        check(MIMEHeader.decodeWords("=?utf-8?B?w4l0w6k=?= =?utf-8?Q?_=C3=A0_Lisbonne?=") == "Été à Lisbonne", "mots encodés B et Q, accolés")
        check(MIMEHeader.decodeWords("=?iso-8859-1?Q?R=E9union?= demain") == "Réunion demain", "Latin-1")
        let (type, parameters) = MIMEHeader.parameters("attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf; size=12")
        check(type == "attachment" && parameters["filename"] == "résumé.pdf", "nom de fichier RFC 2231")
        let (_, continued) = MIMEHeader.parameters("application/pdf; name*0=\"long\"; name*1=\"-nom.pdf\"")
        check(continued["name"] == "long-nom.pdf", "suite de paramètres RFC 2231")
        let raw = """
        From: =?utf-8?Q?Jos=C3=A9?= <jose@exemple.fr>
        To: "Moreau, Camille" <camille@exemple.fr>, b@c.fr
        Subject: Devis
        Content-Type: multipart/mixed; boundary="mix"

        --mix
        Content-Type: multipart/alternative; boundary=alt

        --alt
        Content-Type: text/plain; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable

        Voici le devis, =E0 bient=F4t.=
         Fin.
        --alt
        Content-Type: multipart/related; boundary=rel

        --rel
        Content-Type: text/html; charset=utf-8

        <p>Voici <img src="cid:logo@x"></p>
        --rel
        Content-Type: image/png
        Content-ID: <logo@x>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --rel--
        --alt--
        --mix
        Content-Type: application/pdf; name="devis.pdf"
        Content-Disposition: attachment; filename="devis.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --mix--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let message = MailMessage(raw: Data(raw.utf8))
        check(message.from.first?.name == "José", "expéditeur décodé")
        check(message.to.count == 2 && message.to.first?.name == "Moreau, Camille", "virgule entre guillemets dans un nom")
        check(message.plainText?.hasPrefix("Voici le devis, à bientôt. Fin.") == true, "texte quoted-printable en Latin-1, coupure douce")
        check(message.html?.contains("data:image/png;base64,iVBORw0KGgo=") == true, "image intégrée (cid:) en data:")
        check(message.attachments.map(\.filename) == ["devis.pdf"] && message.attachments.first?.data == Data("%PDF-1.4\n".utf8), "pièce jointe base64")
        check(!message.hasRemoteImages, "pas d'image distante")
        check(MailMessage(raw: Data("Content-Type: text/html\r\n\r\n<img src=\"https://t.test/p.gif\">".utf8)).hasRemoteImages, "pixel espion repéré")
        check(MailMessage(raw: Data("Subject: x\r\n\r\nCorps".utf8)).plainText == "Corps", "message sans Content-Type")
    }

    private static func dates() {
        print("Dates")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 19))!
        func at(_ day: Int, _ hour: Int, year: Int = 2026, month: Int = 10) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 5))! }
        check(MailDate.listLabel(at(18, 9), now: now, calendar: calendar).contains("09:05") || MailDate.listLabel(at(18, 9), now: now, calendar: calendar).contains("9:05"), "aujourd'hui : l'heure")
        check(MailDate.listLabel(at(17, 9), now: now, calendar: calendar) == "hier", "hier")
        check(MailDate.listLabel(at(14, 9), now: now, calendar: calendar) == "mercredi", "dans la semaine : le jour")
        check(MailDate.listLabel(at(1, 9), now: now, calendar: calendar) == "1 oct.", "plus tôt : le jour et le mois")
        check(MailDate.listLabel(at(1, 9, year: 2025), now: now, calendar: calendar) == "1 oct. 2025", "une autre année : l'année")
    }

    private static func htmlPolicy() {
        print("HTML protégé")
        let blocked = HTMLMessageView.page("<head><meta http-equiv=\"Content-Security-Policy\" content=\"img-src *\"></head>", allowsRemote: false)
        check(blocked.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: cid:;"), "la politique de l'app passe avant celle du message")
        check(HTMLMessageView.page("", allowsRemote: true).contains("img-src data: cid: https: http:"), "« Charger les images » les autorise")
    }

    private static func cacheChecks() async {
        print("Cache et recherche")
        let cache = MailCache(path: ":memory:")
        let account = UUID()
        func envelope(_ uid: Int, _ subject: String, seen: Bool = false) -> MessageEnvelope {
            MessageEnvelope(uid: uid, flags: seen ? ["\\Seen"] : [], date: Date(timeIntervalSince1970: Double(uid) * 1000), size: 10, subject: subject,
                            from: [MailAddress(name: "Camille Moreau", address: "camille@exemple.fr")], to: [], cc: [], messageID: nil)
        }
        await cache.checkValidity(account: account, mailbox: "INBOX", validity: 1)
        await cache.insert([envelope(1, "Réunion lundi"), envelope(2, "Facture d'octobre", seen: true), envelope(3, "Lisbonne")], account: account, mailbox: "INBOX")
        var list = await cache.messages(account: account, mailbox: "INBOX")
        check(list.map(\.uid) == [3, 2, 1], "plus récent d'abord")
        let highest = await cache.highestUID(account: account, mailbox: "INBOX")
        check(highest == 3 && list[1].isSeen, "plus grand UID, drapeau lu")
        let accentless = await cache.search(account: account, text: "reunion")
        check(accentless.map(\.uid) == [1], "recherche sans accents")
        let prefixes = await cache.search(account: account, text: "fact oct")
        check(prefixes.map(\.uid) == [2], "début des mots, plusieurs mots")
        let bySender = await cache.search(account: account, text: "moreau")
        check(bySender.count == 3, "recherche par expéditeur")
        await cache.storeBody(Data("x".utf8), text: "Le train pour Sintra part de Rossio", message: list[0].id)
        let inText = await cache.search(account: account, text: "sintra")
        check(inText.map(\.uid) == [3], "recherche dans le texte d'un message lu")
        let kept = await cache.body(message: list[0].id)
        check(kept == Data("x".utf8), "message gardé")
        await cache.updateFlags([1: ["\\Seen"]], account: account, mailbox: "INBOX")
        await cache.removeMessages(account: account, mailbox: "INBOX", uids: [2])
        list = await cache.messages(account: account, mailbox: "INBOX")
        check(list.map(\.uid) == [3, 1] && list[1].isSeen, "drapeaux mis à jour, message disparu du serveur retiré")
        let removed = await cache.search(account: account, text: "facture")
        check(removed.isEmpty, "retiré aussi de la recherche")
        await cache.checkValidity(account: account, mailbox: "INBOX", validity: 2)
        let renumbered = await cache.messages(account: account, mailbox: "INBOX")
        let forgottenBody = await cache.body(message: list[0].id)
        check(renumbered.isEmpty && forgottenBody == nil, "UIDVALIDITY changé : la boîte est oubliée")
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
