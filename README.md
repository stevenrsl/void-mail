# Void Mail

**Un courrier qui s'efface derrière le message.** Version **0.0.2** (préversion : lire). Void Mail est le troisième compagnon de Void et de [Void Notes](../Void%20Notes) : même palette, même chrome sombre, mêmes réglages d'apparence, rien de superflu à l'écran. Le projet et ses choix sont décrits dans [CONCEPT.md](CONCEPT.md).

- Swift + SwiftUI, AppKit là où c'est utile (fenêtre, barre de titre)
- Mac : Apple silicon, macOS 14 minimum. iPhone : plus tard, sur `Shared/`
- **≈ 1,9 Mo** (build Release), aucune dépendance externe (Foundation, Security, CryptoKit, AuthenticationServices, WebKit, SQLite du système)
- Aucun compte Void, aucun serveur intermédiaire : l'app parle directement aux serveurs IMAP et SMTP de l'hébergeur

![Void Mail, thème sombre (comptes de démonstration)](docs/screenshots/sombre.png)

![Un message HTML, son pixel espion bloqué](docs/screenshots/html-protege.png)

| | |
|---|---|
| ![Thème clair, accent rose, teinte pêche](docs/screenshots/clair-peche.png) | ![Premier lancement](docs/screenshots/premier-lancement.png) |
| ![Ajouter un compte sur son propre domaine](docs/screenshots/compte-domaine.png) | ![Outlook : connexion Microsoft en attente d'identifiant](docs/screenshots/compte-outlook.png) |

## Compiler et lancer

Prérequis : Xcode 16 ou plus récent (projet au format « dossiers synchronisés », comme Void et Void Notes ; testé avec Xcode 27), un Mac Apple silicon.

**Avec Xcode** : ouvrir `VoidMail.xcodeproj`, choisir le schéma *VoidMail* → *My Mac*, puis ⌘R. Comme dans Void Notes, une post-action du schéma copie l'app compilée dans `/Applications` (compte rendu dans `build/copy-to-applications.log`).

**En ligne de commande** :

```bash
xcodebuild -project VoidMail.xcodeproj -target VoidMail -configuration Release SYMROOT="$PWD/build/DerivedData/Build/Products" OBJROOT="$PWD/build/DerivedData/Build/Intermediates.noindex" build
```

```bash
./scripts/install.sh
```

```bash
./scripts/make-dmg.sh
```

**Signature** : certificat *Apple Development* de l'équipe `5Q6B9P9723`, comme Void et pas en ad hoc comme Void Notes. macOS reconnaît ainsi l'app d'un build à l'autre et ne redemande pas le mot de passe de session pour les éléments du trousseau. L'app est sandboxée, avec une seule autorisation : les connexions réseau sortantes.

L'icône est générée par script (`swift scripts/make-icon.swift`) : une enveloppe sur la nuit de Void, scellée par son éclipse.

## Comptes

Réglages (⌘,) → Comptes, ou ⇧⌘N, ou le « + » en bas de la barre latérale. On tape l'adresse, l'app en déduit les serveurs (table locale : rien ne quitte le Mac pour les trouver). « Se connecter » joint les deux serveurs, se connecte et liste les boîtes **avant** de garder quoi que ce soit ; une étape qui échoue dit pourquoi, en clair.

| Hébergeur | Connexion | Serveurs |
|---|---|---|
| iCloud (`icloud.com`, `me.com`, `mac.com`) | mot de passe pour app | `imap.mail.me.com:993` TLS · `smtp.mail.me.com:587` STARTTLS |
| Gmail | mot de passe d'application (validation en deux étapes) | `imap.gmail.com:993` · `smtp.gmail.com:465` TLS |
| Outlook.com, Hotmail, Live | **OAuth Microsoft uniquement** | `outlook.office365.com:993` · `smtp.office365.com:587` STARTTLS |
| Fastmail | mot de passe d'application | `imap.fastmail.com:993` · `smtp.fastmail.com:465` TLS |
| Proton (`proton.me`…) | mot de passe de **Proton Mail Bridge** | `127.0.0.1:1143` · `127.0.0.1:1025` STARTTLS |
| Autre domaine | au choix | `imap.<domaine>:993` · `smtp.<domaine>:465`, à vérifier ; « Hébergeur » propose Proton, iCloud, Fastmail ou Microsoft 365 pour une adresse sur son propre domaine |

- **Secrets** : le mot de passe ou les jetons OAuth vont dans le trousseau de session (service `app.void.mail`), jamais dans les fichiers ni les préférences. Retirer un compte les retire.
- **Chiffrement** : TLS dès le premier octet, ou STARTTLS. Une connexion en clair n'est permise que vers ce Mac. Le certificat auto-signé de Proton Mail Bridge n'est accepté que pour `127.0.0.1` / `localhost`.
- **OAuth Microsoft, prêt à brancher** : PKCE dans la feuille de connexion de macOS (`ASWebAuthenticationSession`, session éphémère), SASL `XOAUTH2`, jeton rafraîchi une minute avant son expiration. Pour l'activer, enregistrer une application sur le portail Azure (gratuit, sans audit) :
  1. *App registrations* → *New registration*, comptes « Any Entra ID tenant + personal Microsoft accounts » ;
  2. *Authentication* → *Mobile and desktop applications*, URI de redirection `voidmail://oauth` ;
  3. *API permissions* → Office 365 Exchange Online (ou Microsoft Graph) : `IMAP.AccessAsUser.All`, `SMTP.Send`, `offline_access` ;
  4. copier l'*Application (client) ID* dans `Config/Info.plist` → `VoidMailMicrosoftClientID`.

  Tant qu'il est vide, la connexion Microsoft s'affiche grisée, avec cette raison. Google suit le même code (`VoidMailGoogleClientID`), volontairement vide : voir CONCEPT.md.

**Où sont les comptes** : `~/Library/Containers/app.void.mail/Data/Library/Application Support/Void Mail/accounts.json` (adresse, serveurs, mode de connexion, boîtes trouvées). Un fichier illisible n'est jamais écrasé : il est mis de côté (`accounts.unreadable-….json`) et la fenêtre le dit.

## La fenêtre

La mise en page de Void Notes, avec une colonne de plus :
- les boîtes sur le cadre : Réception, Archives, Envoyés, Brouillons, Indésirables, Corbeille (reconnues par leurs attributs SPECIAL-USE, ou par leur nom sur les serveurs qui n'en ont pas), un trait, puis les autres dossiers du serveur en gris, en retrait selon leur profondeur, avec leurs noms accentués décodés (UTF-7 modifié) ;
- les messages et le message, sur la feuille posée sur le cadre (voir « Lire ») ;
- les comptes en bas de la barre latérale, comme les espaces de Void Notes (⌃⌘← / ⌃⌘→ pour passer de l'un à l'autre).

Réglages → Apparence : thème, couleur d'accent et teinte de la fenêtre, **le même code et les mêmes clés** que Void et Void Notes (`Shared/App/Theme.swift`, `ChromeTint.swift`).

## Lire

- **La liste** : expéditeur et date (« 15:41 », « hier », « vendredi », « 2 oct. »), objet ; non lu en clair avec un point d'accent, lu en gris. ↑ ↓ ou J K pour passer d'un message à l'autre, U (ou ⇧⌘U) pour lu / non lu, ⌘R pour relever.
- **Relève** : à l'ouverture d'une boîte, au retour dans l'app et par ⌘R. La première visite d'une boîte rapporte ses **300 derniers messages** ; ensuite seuls les nouveaux, les drapeaux des autres, et ce qui a disparu du serveur est retiré. Une connexion IMAP par compte, gardée ouverte, rouverte une fois si elle est tombée.
- **Le message** : l'objet en titre, la ligne de l'expéditeur et de la date en petite chasse fixe, comme les dates d'une note. Ouvrir un message le marque lu, sur le serveur aussi. Un texte brut prend la typographie de l'app, ses adresses deviennent des liens ; un message HTML garde sa page blanche, sur une carte, **sans JavaScript, sans cookies, sans rien charger d'Internet** (une politique de sécurité de contenu passe devant celle du message). « Charger les images » les autorise pour ce message. Les images intégrées (`cid:`) s'affichent toujours. Un lien s'ouvre dans le navigateur.
- **Pièces jointes** : en cartes (icône, nom, taille) sous l'en-tête ; un clic en ouvre une copie dans son app.
- **Recherche** : dans toutes les boîtes du compte, sur l'objet, l'expéditeur et le texte des messages déjà ouverts, au début des mots, accents ignorés (FTS5).
- **Cache** : `mail.sqlite` à côté de `accounts.json` : enveloppes des boîtes visitées, messages ouverts, index de recherche. Le serveur reste la vérité : si la boîte est renumérotée (UIDVALIDITY), ce que le cache en savait est oublié. Retirer un compte retire aussi son cache.
- **Décodage** : MIME complet (parties imbriquées, quoted-printable, base64, jeux de caractères, mots encodés RFC 2047, noms de fichier RFC 2231), réponses IMAP lues en octets bruts, littéraux compris.

## État (honnête)

✅ terminé et vérifié par l'auto-test · ☑️ terminé, vérifié à la compilation et sur capture, pas par un test automatisé · 🟡 partiel · ❌ pas encore.

- ✅ SASL `PLAIN` et `XOAUTH2`
- ✅ Réponses IMAP : `LIST` (guillemets, atomes, `NIL`, échappements, littéraux), capacités, noms en UTF-7 modifié (décodage et encodage)
- ✅ Rôle et ordre des boîtes, avec ou sans SPECIAL-USE
- ✅ Annuaire des hébergeurs, hébergeurs pour un domaine perso, ports usuels
- ✅ Refus des connexions en clair hors de ce Mac
- ✅ Comptes enregistrés sans aucun secret ; trousseau (en mémoire pendant le test)
- ✅ **Connexions réelles, sans identifiants** (`-network YES`) : IMAP en TLS (Gmail), IMAP passé en STARTTLS (Microsoft), SMTP passé en STARTTLS (iCloud), mauvais mot de passe refusé avec un message clair
- ☑️ Feuille d'ajout de compte, barre latérale, barre des comptes, réglages, apparence (captures ci-dessus)
- ✅ Réponses FETCH (enveloppes, littéraux, drapeaux), MIME (parties imbriquées, quoted-printable Latin-1, images `cid:`, pièces jointes base64, pixel espion repéré), dates de la liste, politique HTML, cache et recherche (ordre, accents, mots partiels, retrait, UIDVALIDITY)
- ☑️ **Connexion complète d'un vrai compte** : vérifiée à la main avec un compte Proton (domaine perso, via Bridge) — boîtes listées, SMTP authentifié
- ☑️ Liste des messages, message texte et HTML, bandeau des images, pièces jointes (captures ci-dessus, comptes de démonstration)
- 🟡 **Relève sur un vrai compte** : écrite, pas encore essayée ; à faire sur le compte Proton
- 🟡 **OAuth Microsoft** : écrit, jamais exécuté de bout en bout (pas d'identifiant Azure, pas de compte Outlook)
- ❌ `IDLE` (les nouveaux messages arrivent à ⌘R ou au retour dans l'app), messages plus anciens que les 300 derniers
- ❌ Lecture épurée, archiver / supprimer, épingler
- ❌ Compositeur (éditeur de Void Notes), envoi, envoi différé
- ❌ Ponts avec Void et Void Notes, `mailto:` (déclaré dans `Config/Info.plist`, pas encore traité)
- ❌ iPhone

## Vérifier

```bash
"build/DerivedData/Build/Products/Debug/Void Mail.app/Contents/MacOS/Void Mail" -selfTest YES
```

86 vérifications avec `-network YES` (82 sans). Le code de sortie est le nombre d'échecs. Le test ne touche ni aux vrais comptes, ni aux préférences, ni au trousseau.

Autres arguments (builds Debug) : `-demo YES` (deux comptes de démonstration et leur Réception ; `-openUID 101` ou `103` ouvre un message texte ou HTML), `-addAccount YES -address <adresse>` (la feuille ouverte), `-theme light -accent pink -tint peach` (l'apparence), `-snapshot YES` (une capture de la fenêtre, ou de la feuille ouverte, en PNG base64 sur la sortie standard, la seule sortie que le bac à sable laisse lire) :

```bash
"build/DerivedData/Build/Products/Debug/Void Mail.app/Contents/MacOS/Void Mail" -demo YES -snapshot YES | sed -n 's/^SNAPSHOT://p' | base64 -d > fenetre.png
```

## Organisation du code

| Dossier | Contenu |
|---|---|
| `Shared/App` | Préférences (`AppSettings`), palette (`Theme`), teinte de la fenêtre (`ChromeTint`) : repris de Void Notes |
| `Shared/Mail` | Compte, serveur, boîte (`MailAccount`), hébergeurs (`ProviderDirectory`), trousseau (`Keychain`), OAuth (`OAuth`), connexion ligne à ligne et SASL (`MailStream`), `IMAPClient` et ses réponses (`IMAPValue`), `SMTPClient`, MIME (`MIME`), cache et recherche (`MailCache`), connexion par compte et relève (`AccountSession`), comptes sur disque et vérification d'un compte (`AccountStore`), état de la fenêtre (`MailModel`), dates (`MailDate`) |
| `Shared/Debug` | Arguments de lancement et comptes de démonstration (builds Debug) |
| `VoidMail/App` | Mac : point d'entrée, menus |
| `VoidMail/UI` | Mac : fenêtre, barre latérale et comptes (`MailboxSidebar`), liste (`MessageList`), message et HTML protégé (`MessageView`), ajout d'un compte (`AccountSheet`), cadre de la fenêtre (`AppKitBridges`) |
| `VoidMail/Settings` | Mac : réglages |
| `VoidMail/Debug` | Mac : auto-test (builds Debug uniquement) |
