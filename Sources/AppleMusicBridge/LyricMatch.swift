import Foundation

/// Decides whether a cache entry *is* the track that is playing.
///
/// Why this lives in its own file
/// ------------------------------
/// It has no dependency beyond Foundation, so `tools/verify_match.swift` can
/// compile it on its own with a bare `swiftc` and assert the rules. This
/// machine has no Xcode, so XCTest is unavailable and swift-testing's
/// `lib_TestingInterop.dylib` is missing from the Command Line Tools —
/// `swift test` cannot run here at all. The self-check is what actually
/// guards these rules, on every build.
public enum LyricMatch {

    /// Lowercase + strip punctuation/whitespace so titles compare reliably
    /// across "Don't Stop" / "Dont Stop" style differences.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let allowed = lowered.filter { $0.isLetter || $0.isNumber }
        return allowed.isEmpty ? lowered.filter { !$0.isWhitespace } : allowed
    }

    /// Compare one cache entry against the track being played.
    ///
    /// Why acceptance is separate from the score
    /// -----------------------------------------
    /// An earlier version summed weighted signals and accepted anything over
    /// a threshold. "Same artist" alone scored 4 and the threshold *was* 4,
    /// so when 《珠玉》 started playing while the cache still held only the
    /// previous track 《我管不住我自己》 (same artist, same album), the app
    /// displayed that track's 69 lines — the lyrics looked simply wrong until
    /// you hit refresh. A score can rank candidates; it cannot decide who
    /// they are. Identity needs a gate: the title must agree, or the artist
    /// *and* duration must both agree.
    ///
    /// Inputs are expected to be normalised.
    public static func evaluate(candidateTitle: String,
                                candidateArtist: String,
                                candidateDuration: TimeInterval,
                                targetTitle: String,
                                targetArtist: String,
                                targetDuration: TimeInterval) -> (score: Double, accepted: Bool) {
        // Guard the empty side too: `"".contains` is always true, so an
        // entry with no title would otherwise "contain" every title.
        let titleExact = !targetTitle.isEmpty && candidateTitle == targetTitle
        let titlePartial = !targetTitle.isEmpty && !candidateTitle.isEmpty
            && (candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle))
        let artistExact = !targetArtist.isEmpty && candidateArtist == targetArtist
        let artistPartial = !targetArtist.isEmpty && !candidateArtist.isEmpty
            && (candidateArtist.contains(targetArtist) || targetArtist.contains(candidateArtist))
        let durationOK = candidateDuration > 0 && targetDuration > 0
            && abs(candidateDuration - targetDuration) < 2.5

        let accepted = titleExact
            || (titlePartial && (artistExact || artistPartial || durationOK))
            || (artistExact && durationOK)

        var score = 0.0
        if titleExact { score += 10 } else if titlePartial { score += 5 }
        if artistExact { score += 3 } else if artistPartial { score += 1 }
        if durationOK { score += 2 }
        return (score, accepted)
    }
}
