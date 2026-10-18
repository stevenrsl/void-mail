import AppKit
import SwiftUI

/// Gives access to the hosting NSWindow to configure it once.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// What is behind the window (desktop, other apps), blurred: under a tinted frame and the frosted
/// glass behind "Aucun message ouvert". Stays frosted in an inactive window; « Réduire la
/// transparence » makes it opaque.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The frame of the window (`ChromeBackground`), behind everything, the toolbar included: the
/// toolbar belongs to macOS — the content starts below it — so the frame is drawn in two pieces
/// of one picture the size of the window (`WindowChrome`), the tint's gradient running on from
/// one to the other: behind the toolbar, by a view at the back of the title bar; behind the
/// content, by the content itself (`MainWindowView`). Not by one view at the back of the
/// window's frame view: macOS 27 then lays the toolbar out anew, and in the light theme its
/// buttons fall half their height lower, onto the sidebar. The view takes no click: the toolbar's
/// empty places still move the window. The window itself has no background color, which macOS
/// would paint flat under the toolbar.
@MainActor
enum WindowBackdrop {
    /// The height of the window, which the two pieces are cut from.
    @Observable final class Metrics {
        var windowHeight: CGFloat = 0
        /// The piece behind the toolbar is in place: the content draws the rest.
        var split = false
        /// The window followed — a new one when the window is closed then shown again.
        @ObservationIgnored weak var window: NSWindow?
        @ObservationIgnored var observer: Any?
    }
    static let metrics = Metrics()

    static func install(in window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        metrics.windowHeight = window.frame.height
        if metrics.window !== window {
            metrics.observer.map(NotificationCenter.default.removeObserver)
            metrics.window = window
            metrics.observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { metrics.windowHeight = window.frame.height } }
            }
        }
        // The title bar holds the window's buttons and the toolbar; without it (a layout of
        // macOS this doesn't know), the window's frame view.
        guard let frame = window.contentView?.superview else { return }
        let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview
        let host = titlebar.flatMap { $0 === frame || $0.superview !== frame ? nil : $0 } ?? frame
        guard !host.subviews.contains(where: { $0 is Backdrop }) else { return }
        let view = Backdrop(rootView: AnyView(WindowChrome(edge: host === frame ? nil : .top).environment(AppSettings.shared)))
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view, positioned: .below, relativeTo: nil)
        metrics.split = host !== frame
    }

    private final class Backdrop: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// A piece of the window's frame: the top (behind the toolbar) or the bottom (behind the content)
/// of `ChromeBackground` drawn the size of the window — nil: the whole of it.
struct WindowChrome: View {
    let edge: VerticalEdge?

    var body: some View {
        GeometryReader { geometry in
            let height = edge == nil ? geometry.size.height : max(geometry.size.height, WindowBackdrop.metrics.windowHeight)
            ChromeBackground()
                .frame(width: geometry.size.width, height: height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: edge == .top ? .top : .bottom)
                .clipped()
        }
        .ignoresSafeArea()
    }
}

/// Tells when the pointer is used in its window — moved by more than a nudge, clicked, or
/// scrolled — through a local event monitor that lets every event go on its way.
struct PointerWatcher: NSViewRepresentable {
    let onPointer: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onPointer = onPointer
        return view
    }

    func updateNSView(_ nsView: WatcherView, context: Context) {
        nsView.onPointer = onPointer
    }

    final class WatcherView: NSView {
        var onPointer: (() -> Void)?
        private var monitor: Any?
        /// How far the pointer went since the last keystroke: a palm grazing the trackpad isn't a move.
        private var travelled: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            switch event.type {
            case .keyDown:
                travelled = 0
            case .mouseMoved:
                travelled += abs(event.deltaX) + abs(event.deltaY)
                if travelled > 12 { travelled = 0; onPointer?() }
            default:
                onPointer?()
            }
        }
    }
}
