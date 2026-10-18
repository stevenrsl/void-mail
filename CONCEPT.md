# Void Mail — proposition

**Un courrier qui s'efface derrière le message.** Troisième compagnon de [Void](../../Documents/GitHub/Void) et de [Void Notes](../Void%20Notes) : même palette, même chrome sombre, mêmes espaces, rien de superflu à l'écran. Une liste, un message, et on répond comme on écrit une note.

## Ce que Void et Void Notes ont en commun (et que Void Mail reprend tel quel)

| Principe | Void | Void Notes | Void Mail |
|---|---|---|---|
| Moteur natif, aucune dépendance | WebKit, SQLite, CommonCrypto du système | SwiftUI + `NSTextView` | `Network.framework` (IMAP/SMTP en TLS), SQLite du système, WebKit pour le HTML |
| Poids | ≈ 9 Mo | ≈ 2 Mo | **objectif ≈ 3–4 Mo** |
| Chrome qui s'efface | barre latérale masquable, chrome minimal | la liste s'estompe quand on tape | la liste s'estompe quand on lit ou écrit |
| Apparence | `Theme` + `ChromeTint` : sombre par défaut, 5 accents pastel, 8 teintes, dégradé façon Firn, 82 % translucide | identique (mêmes clés `UserDefaults`) | **identique** — copier `Shared/App/Theme.swift` et `ChromeTint.swift` |
| Espaces | Personnel, Travail… (stockage séparé) | idem, icônes en bas de la barre | **un espace = un ou plusieurs comptes** |
| Local d'abord, pas de compte Void | session et historique sur le Mac | un JSON par note, iCloud Drive facultatif | cache local SQLite ; le serveur IMAP reste la vérité |
| Honnêteté | « État des fonctionnalités (honnête) » ✅ ☑️ 🟡 ❌ | `docs/ETAT-V0.1.md` | même grille dès la v0.1 |
| Auto-tests intégrés | `-VoidSelfTest features` | `-selfTest YES` (~380 contrôles) | `-selfTest YES` contre un **faux serveur IMAP/SMTP local** |
| Scripts | `install.sh`, `make-dmg.sh`, `make-icon.swift` | idem | idem (icône : l'éclipse de Void sur une enveloppe) |
| Mac d'abord, iPhone ensuite | cible `VoidiOS` | cible `VoidNotesiOS`, code dans `Shared/` | Mac seul en v0.1, `Shared/` prêt pour l'iPhone |

## Ce qu'est un client mail « dans l'esprit Void »

### 1. Trois colonnes, dont deux qui s'effacent

- **Barre latérale** : Réception, puis Archives, Envoyés, Brouillons, Corbeille — les autres dossiers IMAP repliés sous « Dossiers » (gris, chevrons au survol, comme Void Notes). Les espaces en bas.
- **Liste** : une ligne par conversation — expéditeur, objet, heure à droite (« 15:41 », « hier », « 1 oct. »), aperçu dans l'infobulle. Non lu = texte clair + point d'accent ; lu = gris. Aucune autre couleur.
- **Message** : la feuille posée sur le cadre, exactement comme la note. L'objet en titre, la ligne de dates en petite mono (`De Camille · aujourd'hui à 15:41`).
- Dès qu'on lit (défilement) ou qu'on écrit, liste et boutons s'estompent ; ils reviennent au premier mouvement du pointeur.

### 2. Lire sans être lu

- **HTML dans un `WKWebView` sans JavaScript**, images distantes **bloquées par défaut** (pixels espions). « Charger les images » pour ce message, ou toujours pour cet expéditeur.
- Le bloqueur de Void (`WKContentRuleList`) réutilisé pour couper les traqueurs connus même quand les images sont autorisées ; liens de suivi (`utm_*`, redirections) nettoyés au clic.
- **Lecture épurée** (⌘⇧R, comme le mode lecture de Void) : le message rendu en texte, dans la typo et la teinte de l'app — les newsletters deviennent lisibles.
- Les citations repliées (« … 3 messages précédents »), les signatures estompées.

### 3. Écrire comme dans Void Notes

- Le compositeur **est** l'éditeur de Void Notes : `TypingRules` et `NoteFormat` de `Shared/Editor` réutilisés tels quels. `# `, `- `, `[] `, `**gras**`, `==surligné==`, `> ` se transforment en tapant.
- À l'envoi : `multipart/alternative` — un HTML sobre (aucune police, aucune couleur imposée) et sa version texte en Markdown lisible.
- Brouillon enregistré 0,4 s après la dernière frappe (même rythme que les notes), dans le dossier Brouillons IMAP.
- Pièces jointes en cartes (icône, nom, type, taille), glissées-déposées ou collées, comme dans les notes.
- **Envoi différé de 10 s** (« Envoyé · Annuler ») par défaut, sans réglage à chercher.

### 4. Un geste par message

Réception = à traiter. Chaque message en sort par un seul geste :

| Geste | Mac | iPhone (plus tard) |
|---|---|---|
| Archiver | E | balayage à gauche |
| Corbeille | ⌫ | balayage à gauche, long |
| Répondre / à tous / transférer | R / ⇧R / F | — |
| Marquer non lu | U | balayage à droite |
| Épingler en tête | ⌃⌘P (comme les notes) | balayage à droite |
| Suivant / précédent | J / K, ⌥⌘↓ / ⌥⌘↑ | — |
| Rechercher | ⌘F (locale, instantanée) | loupe |
| Barre de commande | ⌘L (comme Void) : « écrire à Camille », « archives juin », « non lus » | — |

Pas de règles, pas de libellés de couleur, pas d'onglets « Promotions ». L'épinglage et l'archive suffisent.

### 5. Le trio qui se parle

- **Void → Void Mail** : Void Mail se déclare gestionnaire de `mailto:` ; « Envoyer la page par mail » dans Void (titre + lien + texte du mode lecture), sur le modèle de `voidnotes://new`.
- **Void Mail → Void Notes** : « Envoyer vers Void Notes » (⌘⇧M, le même raccourci que Void) par `voidnotes://new` ou `voidnotes://append`, avec la ligne `Source :` qui pointe vers le message (`voidmail://message?id=<Message-ID>`). Le sélecteur de notes de Void (`NotesPickerOverlay`, presse-papiers `app.void.notes.directory`) se réutilise tel quel.
- **Void Notes → Void Mail** : « Envoyer par mail » transforme une note en brouillon, mise en forme comprise (même format, aucune conversion perdue).
- **Liens** : un clic dans un message ouvre Void s'il est le navigateur par défaut.

### 6. Comptes et données

- **IMAP + SMTP**, deux façons de se connecter, choisies par compte (`MailAuth`) :
  - **mot de passe d'application** (SASL `PLAIN`) : iCloud, Fastmail, Gmail (validation en deux étapes requise), Proton via Bridge, tout hébergeur standard — c'est la voie de la v0.1 ;
  - **OAuth 2** (SASL `XOAUTH2`, PKCE par `ASWebAuthenticationSession`, jeton de rafraîchissement dans le trousseau) : **prêt pour Outlook.com / Hotmail / Microsoft 365**, où Microsoft a coupé l'IMAP par mot de passe. Il ne manque qu'un identifiant client Azure (gratuit, sans audit) dans `Config/Info.plist` → `VoidMailMicrosoftClientID` ; tant qu'il est vide, l'option dit pourquoi elle est grisée. Gmail en OAuth reste prévu par le même code, mais pas activé : le scope `mail.google.com` est « restreint » (audit CASA payant pour distribuer, jeton de 7 jours en mode test).
- Réglages automatiques par domaine (table locale ; `autoconfig` Thunderbird plus tard).
- **Mots de passe dans le trousseau macOS** — donc signature *Apple Development* comme Void, pas ad hoc comme Void Notes (sinon le trousseau redemande le mot de passe à chaque build).
- **IDLE** sur la Réception tant que l'app est ouverte, relève des autres dossiers à l'ouverture et toutes les 5 min. Pas de serveur de notifications, donc pas de serveur Void du tout.
- Cache : `~/Library/…/Void Mail/mail.sqlite` (en-têtes, structure, corps texte, index **FTS5** pour la recherche), corps HTML et pièces jointes chargés à la demande et gardés 30 jours. Une boîte de 50 000 messages doit tenir sous 300 Mo.
- App sandboxée, une seule autorisation : connexions réseau sortantes.

## Ce que Void Mail ne fait pas

Pas d'IA qui trie ou résume, pas de compte Void, pas de serveur intermédiaire, pas de suivi d'ouverture, pas de signature HTML décorée, pas d'Exchange/EWS, pas de calendrier intégré (les invitations `.ics` s'ouvrent dans l'app Calendrier), pas de dépendance externe.

## Découpage proposé

**v0.1 — lire et répondre (Mac)**
1. Squelette Xcode « dossiers synchronisés », cibles `VoidMail` + `Shared/`, scripts copiés de Void Notes, `Theme`/`ChromeTint` repris.
2. Client IMAP minimal sur `NWConnection` TLS : LOGIN, LIST, SELECT, UID FETCH (ENVELOPE, BODYSTRUCTURE, BODY.PEEK[]), UID STORE, UID MOVE, IDLE. Analyseur MIME (quoted-printable, base64, encodages de mots RFC 2047, multipart).
3. Client SMTP (465 implicite / 587 STARTTLS, AUTH PLAIN/LOGIN).
4. Cache SQLite + FTS5, conversations par `References`/`In-Reply-To`.
5. Interface trois colonnes, lecture HTML protégée, compositeur Void Notes, gestes clavier.
6. Faux serveur IMAP/SMTP en mémoire pour l'auto-test.

**v0.2** — lecture épurée, ponts Void ↔ Void Notes, barre de commande, envoi différé, note rapide de la barre des menus pour écrire un mail.

**v0.3** — OAuth Microsoft activé dès qu'un compte Outlook en a besoin (identifiant Azure à renseigner) ; Gmail en OAuth seulement si l'app est distribuée ; cible iPhone sur `Shared/`.

## Décisions

- **Authentification (18 oct. 2026)** : mots de passe d'application en v0.1 ; OAuth Microsoft codé et prêt, activé par un identifiant client ; Gmail OAuth seulement en cas de distribution.

## Points à trancher

- **Espaces = comptes**, ou espaces libres regroupant plusieurs comptes (une Réception unifiée par espace) ?
- ~~Comptes à faire marcher en premier~~ : `stevenrsl.eu` est chez **Proton** (MX `mail.protonmail.ch`) → Proton Mail Bridge d'abord, puis iCloud/Gmail.
