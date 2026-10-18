import SwiftUI

/// The left of the window: the mailboxes of the account shown — Réception, Archives, Envoyés,
/// Brouillons, Indésirables, Corbeille, then the server's other folders, in grey, indented by
/// their depth — and the accounts at the bottom, as Void Notes' spaces.
struct MailboxSidebar: View {
    @Environment(MailModel.self) private var model
    @Environment(AccountStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if let account = model.currentAccount {
                        let mailboxes = account.sortedMailboxes
                        ForEach(mailboxes) { mailbox in
                            MailboxRow(mailbox: mailbox, selected: model.selectedMailbox == mailbox.path) {
                                model.selectMailbox(mailbox.path)
                            }
                            .disabled(!mailbox.isSelectable)
                            // A line between the special mailboxes and the server's other folders.
                            if mailbox == mailboxes.last(where: { $0.role != .other }), mailbox != mailboxes.last {
                                Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 10)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
            AccountBar()
        }
    }
}

private struct MailboxRow: View {
    let mailbox: Mailbox
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: mailbox.role.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(mailbox.displayName)
                    .font(.system(size: 13, weight: mailbox.role == .other ? .regular : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.accent : mailbox.role == .other ? Theme.secondaryText : Theme.primaryText)
            .padding(.leading, 10 + CGFloat(mailbox.role == .other ? mailbox.depth * 14 : 0))
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(mailbox.path)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The accounts, as small initials at the bottom of the sidebar; the name of the one shown next
/// to them while the pointer is over the bar. « + » adds one.
private struct AccountBar: View {
    @Environment(MailModel.self) private var model
    @Environment(AccountStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(store.accounts) { account in
                let current = model.currentAccount?.id == account.id
                Button { withAnimation(Theme.quick) { model.select(account) } } label: {
                    Text(Self.initial(of: account))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(current ? Theme.onAccent : Theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(current ? Theme.accentFill : Theme.hover))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(account.address)
                .accessibilityLabel(account.address)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            if hovering, let account = model.currentAccount {
                Text(account.name.isEmpty ? account.address : account.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            ChromeButton(symbol: "plus", help: "Ajouter un compte (⇧⌘N)") { model.addingAccount = true }
                .opacity(hovering || store.accounts.isEmpty ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .contentShape(Rectangle())
        .onHover { over in withAnimation(Theme.quick) { hovering = over } }
    }

    static func initial(of account: MailAccount) -> String {
        let source = account.name.isEmpty ? account.address : account.name
        return source.first.map { String($0).uppercased() } ?? "?"
    }
}
