import SwiftUI

/// Root of the window: Void Notes' layout with one more column. The mailboxes on the frame, then
/// the messages of the open mailbox and the message itself, both on the sheet lifted from the
/// frame. The frame, tinted or not, is drawn behind the whole window, toolbar included
/// (`WindowBackdrop`, `WindowChrome`).
struct MainWindowView: View {
    @Environment(AccountStore.self) private var store
    @Environment(MailModel.self) private var model
    @Environment(AppSettings.self) private var settings

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
        .toolbar { MailToolbar(settings: settings) }
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
            if DebugLaunch.isDemo { await model.loadDemo() }
            #endif
            await model.refresh()
        }
        // Back to the app: what came in meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
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
                Button("Ajouter un compte  ⇧⌘N") { model.addingAccount = true }
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

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ChromeButton(symbol: "sidebar.left", help: "Boîtes (⌃⌘S)") {
                withAnimation(Theme.spring) { settings.showsSidebar.toggle() }
            }
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
