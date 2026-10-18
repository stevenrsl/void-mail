import SwiftUI

/// Root of the window: Void Notes' layout with one more column. The mailboxes on the frame, then
/// the messages of the open mailbox and the message itself, both on the sheet lifted from the
/// frame. The frame, tinted or not, is drawn behind the whole window, toolbar included
/// (`WindowBackdrop`, `WindowChrome`).
struct MainWindowView: View {
    @Environment(AccountStore.self) private var store
    @Environment(MailModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(Outbox.self) private var outbox
    @Environment(\.openWindow) private var openWindow

    static let autosaveName = "VoidMailMainWindow"

    var body: some View {
        HStack(spacing: 0) {
            if settings.showsSidebar {
                MailboxSidebar()
                    .frame(width: 230)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                // No account yet: one sheet, and the one thing to do.
                if !store.accounts.isEmpty {
                    MessageList()
                        .frame(width: 320)
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                }
                MessagePane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(MessageSurface(drawsFrame: false))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
            .padding(.leading, settings.showsSidebar ? 0 : 8)
            .padding([.trailing, .bottom], 8)
        }
        .frame(minWidth: 820, minHeight: 460)
        // The window's frame below the toolbar; the toolbar's is drawn by the title bar (`WindowBackdrop`).
        .background { if WindowBackdrop.metrics.split { WindowChrome(edge: .bottom) } }
        .toolbar { MailToolbar(settings: settings) { if let id = outbox.newDraft(account: model.currentAccount) { openWindow(id: "compose", value: id) } } }
        // A draft to show again (an undone or failed send).
        .onChange(of: outbox.reopen) { _, id in
            if let id {
                openWindow(id: "compose", value: id)
                outbox.reopen = nil
            }
        }
        // mailto: links (Void, any app): a new message.
        .onOpenURL { url in
            if let id = outbox.draft(fromMailto: url, account: model.currentAccount) { openWindow(id: "compose", value: id) }
        }
        .alert("Envoi", isPresented: Binding(get: { outbox.sendError != nil }, set: { if !$0 { outbox.sendError = nil } })) {
            Button("OK") {}
        } message: {
            Text(outbox.sendError ?? "")
        }
        .modifier(ChromeToolbarBackground())
        .tint(Theme.accent)
        .background(WindowAccessor(configure: configure))
        .sheet(isPresented: Bindable(model).addingAccount) {
            AccountSheet()
                .environment(settings)
                .environment(store)
                .environment(model)
        }
        .task {
            #if DEBUG
            if DebugLaunch.isDemo {
                await model.loadDemo()
                // `-compose reply` (or `new`): a message being written, for the snapshots.
                switch UserDefaults.standard.string(forKey: "compose") {
                case "reply":
                    try? await Task.sleep(for: .milliseconds(300))
                    if let id = model.replyDraft(all: false) { openWindow(id: "compose", value: id) }
                case "new":
                    let to = UserDefaults.standard.string(forKey: "composeTo") ?? "Camille Moreau <camille@exemple.fr>"
                    if let id = outbox.newDraft(account: model.currentAccount, to: to) { openWindow(id: "compose", value: id) }
                default: break
                }
            }
            #endif
            await model.refresh()
            model.watchInboxes()
        }
        // Back to the app: what came in meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .confirmationDialog("Supprimer définitivement « \(model.confirmingDeletion?.subject ?? "") » ?",
                            isPresented: Binding(get: { model.confirmingDeletion != nil }, set: { if !$0 { model.confirmingDeletion = nil } })) {
            Button("Supprimer définitivement", role: .destructive) {
                if let message = model.confirmingDeletion { withAnimation(Theme.quick) { model.deleteForGood(message) } }
            }
            Button("Annuler", role: .cancel) { model.confirmingDeletion = nil }
        } message: {
            Text("Le message est effacé du serveur. Cela ne s'annule pas.")
        }
        .alert("Opération impossible", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func configure(_ window: NSWindow) {
        window.toolbar?.showsBaselineSeparator = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The content starts below the toolbar: the toolbar's empty places belong to macOS, which
        // moves the window from there (and zooms it on double-click).
        window.styleMask.remove(.fullSizeContentView)
        window.isMovable = true
        window.tabbingMode = .disallowed
        WindowBackdrop.install(in: window)
        window.setFrameAutosaveName(Self.autosaveName)
    }
}

/// No message open: the mark, and the one thing to do.
private struct MessagePane: View {
    @Environment(MailModel.self) private var model
    @Environment(AccountStore.self) private var store

    var body: some View {
        if let summary = model.selectedMessage {
            MessageView(summary: summary)
                .id(summary.id)
        } else {
            nothingOpen
        }
    }

    private var nothingOpen: some View {
        VStack(spacing: 14) {
            VoidLogo(size: 44).opacity(0.9)
            Text(store.accounts.isEmpty ? "Aucun compte" : "Aucun message ouvert")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            if store.accounts.isEmpty {
                Button("Ajouter un compte  ⌥⌘N") { model.addingAccount = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(Theme.accentFill))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The window's toolbar: the mailboxes on the left, in the chrome's grey — the accent is for the message.
private struct MailToolbar: ToolbarContent {
    let settings: AppSettings
    let compose: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ChromeButton(symbol: "sidebar.left", help: "Boîtes (⌃⌘S)") {
                withAnimation(Theme.spring) { settings.showsSidebar.toggle() }
            }
        }
        .plainToolbarItem()
        if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
        ToolbarItem(placement: .primaryAction) {
            ChromeButton(symbol: "square.and.pencil", help: "Nouveau message (⌘N)", action: compose)
        }
        .plainToolbarItem()
    }
}

/// The toolbar shows the window's chrome color rather than a material.
private struct ChromeToolbarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

extension ToolbarContent {
    /// No Liquid Glass capsule behind the item (macOS 26+): the toolbar keeps Void's flat chrome.
    @ToolbarContentBuilder
    func plainToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
