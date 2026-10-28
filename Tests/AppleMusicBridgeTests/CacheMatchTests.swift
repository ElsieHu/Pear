import Foundation
import Testing
@testable import AppleMusicBridge

/// The identity rule behind cache matching.
///
/// These cases exist because of a real bug: 《珠玉》 and 《我管不住我自己》 are
/// by the same artist on the same album, so while 《珠玉》's lyrics had not
/// landed in the cache yet, the app matched — and displayed — the other
/// track's 69 lines. Scoring alone could not catch it; the gate does.
@Suite("缓存歌词匹配的身份门槛")
struct CacheMatchTests {

    private func evaluate(cTitle: String, cArtist: String, cDuration: TimeInterval,
                          tTitle: String, tArtist: String, tDuration: TimeInterval)
        -> (score: Double, accepted: Bool) {
        LyricMatch.evaluate(
            candidateTitle: cTitle, candidateArtist: cArtist, candidateDuration: cDuration,
            targetTitle: tTitle, targetArtist: tArtist, targetDuration: tDuration)
    }

    /// The exact regression: same artist, same album, different song.
    @Test("同艺人不同歌必须被拒绝")
    func sameArtistDifferentTitleIsRejected() {
        let r = evaluate(cTitle: "我管不住我自己", cArtist: "单依纯", cDuration: 261.6,
                         tTitle: "珠玉", tArtist: "单依纯", tDuration: 202.4)
        #expect(r.accepted == false)
    }

    @Test("完全一致时接受且得最高分")
    func exactMatchIsAcceptedAndScoresHighest() {
        let r = evaluate(cTitle: "珠玉", cArtist: "单依纯", cDuration: 202.4,
                         tTitle: "珠玉", tArtist: "单依纯", tDuration: 202.4)
        #expect(r.accepted)
        #expect(abs(r.score - 15.0) < 0.001)
    }

    /// A different artist covering the same title still has the right lyrics
    /// as far as the cache is concerned — the title is the identity.
    @Test("标题一致时艺人不同也接受")
    func titleMatchWinsEvenWhenArtistDiffers() {
        let r = evaluate(cTitle: "珠玉", cArtist: "SomeoneElse", cDuration: 199.0,
                         tTitle: "珠玉", tArtist: "单依纯", tDuration: 202.4)
        #expect(r.accepted)
    }

    /// `"珠玉".contains("")` is true — an untitled entry must not match on
    /// the artist alone.
    @Test("空标题且时长不符时必须拒绝")
    func emptyCandidateTitleNeverMatches() {
        let r = evaluate(cTitle: "", cArtist: "单依纯", cDuration: 261.6,
                         tTitle: "珠玉", tArtist: "单依纯", tDuration: 202.4)
        #expect(r.accepted == false)
    }

    /// …but when artist *and* duration agree it is almost certainly the same
    /// song with missing metadata; rejecting it would wait forever.
    @Test("空标题但艺人+时长一致时允许命中")
    func emptyTitleWithArtistAndDurationIsAccepted() {
        let r = evaluate(cTitle: "", cArtist: "单依纯", cDuration: 202.4,
                         tTitle: "珠玉", tArtist: "单依纯", tDuration: 202.4)
        #expect(r.accepted)
    }

    /// Title unknown to us: artist + duration agreement is the fallback.
    @Test("标题未知时艺人+时长才算命中")
    func artistPlusDurationAcceptedWhenTitleUnknown() {
        let r = evaluate(cTitle: "珠玉", cArtist: "单依纯", cDuration: 202.4,
                         tTitle: "", tArtist: "单依纯", tDuration: 202.4)
        #expect(r.accepted)
    }

    /// Edition suffixes ("鲜花 - Single") must still match the base title.
    @Test("标题带版本后缀仍可匹配")
    func partialTitleWithMatchingDurationIsAccepted() {
        let r = evaluate(cTitle: "鲜花single", cArtist: "回春丹", cDuration: 341.4,
                         tTitle: "鲜花", tArtist: "回春丹", tDuration: 341.4)
        #expect(r.accepted)
    }
}
