import SwiftUI

/// Réglages (⌘,): theme, accent color, tint of the window — Void's and Void Notes' — and the
/// accounts. Every change applies at once.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountStore.self) private var store
    @Environment(MailModel.self) private var model
    @State private var pendingRemoval: MailAccount?

    var body: some View {
        Form {
            Section("Apparence") {
                LabeledContent("Thème") { ThemePicker() }
                LabeledContent("Couleur") { AccentPicker() }
                LabeledContent("Teinte de la fenêtre") { ChromeTintPicker() }
                ChromeTintOptions()
            }
            Section {
                ForEach(store.accounts) { account in
                    LabeledContent {
                        Button("Retirer…", role: .destructive) { pendingRemoval = account }
                    } label: {
                        Text(account.address)
                        Text("\(account.auth.label) · \(account.imap.host)")
                    }
                }
                Button("Ajouter un compte…") { model.addingAccount = true }
            } header: {
                Text("Comptes")
            } footer: {
                Text("Les mots de passe et les jetons de connexion sont dans le trousseau de ce Mac. Retirer un compte ne supprime aucun message du serveur.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .frame(width: 460)
        .confirmationDialog("Retirer « \(pendingRemoval?.address ?? "") » ?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Retirer le compte", role: .destructive) {
                if let account = pendingRemoval { model.forget(account) }
            }
            Button("Annuler", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Son mot de passe est retiré du trousseau et ses messages du cache de ce Mac. Ils restent sur le serveur.")
        }
    }
}

/// Sombre · Clair · Système, drawn with the accent (the system segmented control follows the
/// macOS accent, not Void's).
struct ThemePicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ThemeChoice.allCases) { choice in
                let selected = settings.theme == choice
                Button { settings.theme = choice } label: {
                    Text(choice.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(selected ? Theme.accentSoft : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.hover))
    }
}

/// Five swatches; the choice applies at once everywhere the accent appears.
struct AccentPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccentChoice.allCases) { choice in
                let selected = settings.accent == choice
                Button { withAnimation(Theme.quick) { settings.accent = choice } } label: {
                    Circle()
                        .fill(Theme.swatch(choice))
                        .frame(width: 18, height: 18)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.onAccent)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Theme.swatch(choice) : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(choice.label)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Text(settings.accent.label).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
        }
    }
}
