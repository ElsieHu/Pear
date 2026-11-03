import Foundation

/// Which pieces of information the menu-bar item shows.
///
/// Deliberately a set of independent flags rather than one enum: the user
/// asked to pick any combination (icon only, title only, artist + title, …).
struct MenuBarDisplay: Codable, Equatable, Sendable {
    var showsIcon = true
    var showsTitle = false
    var showsArtist = false

    /// Everything switched off would leave an invisible, unclickable status
    /// item — the app would be unreachable. The icon is the floor.
    var isEffectivelyEmpty: Bool { !showsIcon && !showsTitle && !showsArtist }

    static let `default` = MenuBarDisplay()

    /// Menu bar space is scarce: collapse to one line and cap the length.
    func label(title: String?, artist: String?) -> String {
        var parts: [String] = []
        if showsTitle, let t = title, !t.isEmpty { parts.append(t.trimmed) }
        if showsArtist, let a = artist, !a.isEmpty { parts.append(a.trimmed) }
        guard !parts.isEmpty else { return "" }
        let joined = parts.joined(separator: " · ")
        return joined.count > 30 ? String(joined.prefix(29)) + "…" : joined
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
