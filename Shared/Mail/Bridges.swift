import Foundation
#if os(macOS)
import AppKit
#endif

/// The family's links. Void Mail sends a message to Void Notes (`voidnotes://new`, as Void does
/// with a page), and answers two URLs of its own:
/// - `voidmail://message?id=<Message-ID>`: the message opened again — the « Source : » line of
///   a note made from it;
/// - `voidmail://compose?to=…&subject=…&markdown=…`: a new message, its text in Markdown, read
///   back into the editor's format (Void Notes' « Envoyer par mail », Void's « Envoyer la page
///   par mail »).
enum Bridges {
    static let notesScheme = "voidnotes"
    static let scheme = "voidmail"
    /// A URL carries the note: a long message is cut rather than refused by LaunchServices.
    static let maxTextLength = 20_000

    static var notesInstalled: Bool {
        #if os(macOS)
        URL(string: "\(notesScheme)://new").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        #else
        false
        #endif
    }

    /// Every value fully percent-encoded, so the receiver reads it back however it parses.
    static func encoded(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func query(_ items: [(String, String)]) -> String {
        items.filter { !$0.1.isEmpty }.map { "\($0.0)=\(encoded($0.1))" }.joined(separator: "&")
    }

    /// The note Void Notes makes of a message: its subject as title, its text, and the link back.
    static func noteURL(subject: String, text: String, messageID: String?) -> URL? {
        let body = text.count > maxTextLength ? String(text.prefix(maxTextLength)) + "…" : text
        let source = messageID.flatMap(messageURL)?.absoluteString ?? ""
        return URL(string: "\(notesScheme)://new?" + query([("title", subject), ("text", body), ("url", source)]))
    }

    static func messageURL(_ messageID: String) -> URL? {
        URL(string: "\(scheme)://message?" + query([("id", messageID)]))
    }

    enum Request: Equatable {
        case message(id: String)
        case compose(to: String, subject: String, markdown: String)
    }

    static func request(from url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        switch url.host()?.lowercased() {
        case "message":
            let id = value("id")
            return id.isEmpty ? nil : .message(id: id)
        case "compose":
            return .compose(to: value("to"), subject: value("subject"),
                            markdown: String(value("markdown").prefix(200_000)).replacingOccurrences(of: "\r\n", with: "\n"))
        default:
            return nil
        }
    }
}
