import SwiftUI

/// The middle column: the open mailbox's messages, or what the search found. One line of
/// sender and date, one of subject; unread in clear with a dot of the accent, read in grey —
/// no other color. ↑ ↓ (or J K) go from one to the next.
struct MessageList: View {
    @Environment(MailModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            header
            SearchField(text: $model.query)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            if let error = model.serverError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(3)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message, selected: model.selectedMessageID == message.id,
                                       showsMailbox: !model.query.isEmpty)
                                .id(message.id)
                                .onTapGesture {
                                    focused = true
                                    model.open(message)
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: model.selectedMessageID) { _, id in
                    if let id { withAnimation(Theme.quick) { proxy.scrollTo(id) } }
                }
            }
            .overlay { empty }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { model.move(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.move(by: -1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "jkuJKU")) { press in
            switch press.characters.lowercased() {
            case "j": model.move(by: 1)
            case "k": model.move(by: -1)
            default: model.toggleSeen()
            }
            return .handled
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.query.isEmpty ? (model.currentMailbox?.displayName ?? "") : "Recherche")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(model.currentAccount?.address ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if model.syncing {
                ProgressView().controlSize(.small)
            } else {
                ChromeButton(symbol: "arrow.clockwise", help: "Relever (⌘R)") { Task { await model.refresh() } }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var empty: some View {
        if model.messages.isEmpty, !model.syncing {
            Text(model.query.isEmpty ? "Aucun message" : "Rien trouvé")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct MessageRow: View {
    let message: MessageSummary
    let selected: Bool
    let showsMailbox: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isSeen ? .clear : Theme.accent)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.sender.display.isEmpty ? "(sans expéditeur)" : message.sender.display)
                        .font(.system(size: 13, weight: message.isSeen ? .regular : .semibold))
                        .foregroundStyle(message.isSeen ? Theme.secondaryText : Theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if message.isFlagged {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
                    }
                    Text(MailDate.listLabel(message.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                Text(message.subject.isEmpty ? "(sans objet)" : message.subject)
                    .font(.system(size: 12))
                    .foregroundStyle(message.isSeen ? Theme.secondaryText : Theme.primaryText)
                    .lineLimit(1)
                if showsMailbox {
                    Text(message.mailbox)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(message.sender.address)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The search, in every mailbox of the account (subject, sender, the text of messages read).
private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            TextField("Rechercher", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.hover))
    }
}
