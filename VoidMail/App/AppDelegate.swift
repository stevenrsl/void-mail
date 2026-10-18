import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One window; no "Show Tab Bar" menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated { AppSettings.shared.applyAppearance() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugLaunch.isSelfTest { MainActor.assumeIsolated { SelfTest.run() } }
        // `-addAccount YES`: the sheet that adds an account, open (with `-address`, filled in).
        if UserDefaults.standard.bool(forKey: "addAccount") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { MailModel.shared.addingAccount = true } }
        }
        // `-closeCompose YES` (with `-compose new`): the message being written is closed, as with
        // its close button; « fermeture OK » is printed if the app is still there afterwards.
        if UserDefaults.standard.bool(forKey: "closeCompose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSApp.windows.first { $0.isVisible && $0.title != "Void Mail" && $0.contentView != nil }?.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print(NSApp.windows.contains { $0.isVisible && $0.title.hasPrefix("Nouveau") } ? "fenêtre encore ouverte" : "fermeture OK")
                    exit(0)
                }
            }
        }
        // `-snapshot YES`: a picture of the window, as base64 PNG on the standard output (the
        // sandbox lets the app write nowhere a script can read), then quit; the sheet
        // rather than the window when one is open.
        if UserDefaults.standard.bool(forKey: "snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let main = NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = (main.attachedSheet ?? main).contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: rep)
                print("SNAPSHOT:" + (rep.representation(using: .png, properties: [:])?.base64EncodedString() ?? ""))
                exit(0)
            }
        }
        #endif
    }

    /// A gesture or a message still waiting for its undo delay reaches the server before the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard MailModel.shared.pending != nil || Outbox.shared.sending != nil else { return .terminateNow }
            Task { @MainActor in
                await MailModel.shared.commitPendingNow()
                await Outbox.shared.flushSendingNow()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
