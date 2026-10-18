#if DEBUG
import Foundation

/// Debug builds only. Launch arguments that never touch the real accounts or preferences:
/// `-selfTest YES` runs the checks and quits, `-demo YES` shows sample accounts kept in memory.
/// `-snapshot YES` prints a picture of the window and quits. `-theme`, `-accent` and
/// `-tint` choose the look.
enum DebugLaunch {
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var isSelfTest: Bool { UserDefaults.standard.bool(forKey: "selfTest") }
    static var isRequested: Bool { isDemo || isSelfTest || UserDefaults.standard.bool(forKey: "snapshot") }

    /// Two accounts, as if added and checked: their mailboxes show in the sidebar.
    static var demoAccounts: [MailAccount] {
        guard isDemo else { return [] }
        var personal = MailAccount(name: "Steven", address: "steven@icloud.com", preset: ProviderDirectory.preset(for: "steven@icloud.com"))
        personal.mailboxes = ["INBOX", "Archive", "Sent Messages", "Drafts", "Deleted Messages", "Junk", "Factures", "Voyages", "Voyages/Portugal"]
            .map { Mailbox(path: $0, delimiter: "/", attributes: Mailbox.guessedAttributes(for: $0)) }
        var work = MailAccount(name: "Studio", address: "hello@studio.test", preset: ProviderDirectory.preset(for: "hello@studio.test"))
        work.mailboxes = ["INBOX", "Archives", "Sent", "Drafts", "Trash"]
            .map { Mailbox(path: $0, delimiter: ".", attributes: Mailbox.guessedAttributes(for: $0)) }
        return [personal, work]
    }

    /// The Inbox of the demo accounts: a week of mail, some read.
    static var demoEnvelopes: [MessageEnvelope] {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let rows: [(Int, String, String, String, Double, Bool)] = [
            (101, "Camille Moreau", "camille@exemple.fr", "Lisbonne : le train pour Sintra", 0.4, false),
            (102, "La Poste", "suivi@laposte.test", "Votre colis arrive demain", 3, false),
            (103, "Studio Arpège", "hello@arpege.test", "Les maquettes de la v2, à relire", 20, true),
            (104, "Fastmail", "billing@fastmail.test", "Facture d'octobre", 30, true),
            (105, "Julien", "julien@exemple.fr", "Re: Dîner samedi ?", 50, true),
            (106, "Le Monde diplomatique", "newsletter@monde.test", "Le numéro de novembre est paru", 140, true),
            (107, "Proton", "no-reply@proton.test", "Votre rapport de sécurité mensuel", 400, true),
        ]
        return rows.map { uid, name, address, subject, hours, seen in
            MessageEnvelope(uid: uid, flags: seen ? ["\\Seen"] : [], date: ago(hours), size: 4_000, subject: subject,
                            from: [MailAddress(name: name, address: address)], to: [MailAddress(name: "Steven", address: "steven@icloud.com")],
                            cc: [], messageID: "<\(uid)@demo>")
        }
    }

    /// Bodies of two demo messages: plain text, and HTML with a remote image.
    static let demoBodies: [Int: String] = [
        101: """
        From: Camille Moreau <camille@exemple.fr>
        To: Steven <steven@icloud.com>
        Subject: =?utf-8?Q?Lisbonne_:_le_train_pour_Sintra?=
        Date: Sat, 18 Oct 2026 18:05:00 +0200
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Salut,

        J'ai regard=C3=A9 les horaires : un train part de Rossio toutes les 20 minutes, 40 minutes de trajet. =
        On pourrait prendre celui de 9 h 11 et =C3=AAtre au Palais de la Pena avant la foule.

        Les billets : https://www.cp.pt

        =C3=80 samedi,
        Camille
        """,
        103: """
        From: Studio Arpege <hello@arpege.test>
        Subject: Les maquettes de la v2
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8

        Les maquettes sont prêtes.
        --b1
        Content-Type: text/html; charset=utf-8

        <html><body style="font-family: -apple-system; padding: 8px"><h2>Les maquettes de la v2</h2>
        <p>Bonjour Steven, voici les <b>maquettes</b> de l'écran d'accueil.</p>
        <img src="https://tracker.example.test/pixel.gif" width="1" height="1">
        <p><a href="https://arpege.test/v2">Voir le dossier</a></p></body></html>
        --b1--
        """,
    ]
}
#endif
