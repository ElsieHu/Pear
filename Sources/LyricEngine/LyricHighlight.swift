import Foundation

extension TimedLyrics {

    /// Index of the line that is currently "active" at `time`.
    /// Returns the last line whose start time has passed.
    public func activeLineIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var idx = 0
        for (i, line) in lines.enumerated() {
            if line.startTime <= time {
                idx = i
            } else {
                break
            }
        }
        return idx
    }

    /// The line active at `time` (or nil).
    public func activeLine(at time: TimeInterval) -> LyricLine? {
        guard let i = activeLineIndex(at: time) else { return nil }
        return lines[i]
    }

    /// Progress (0...1) of a whole line at `time`, used for the karaoke sweep.
    public func lineProgress(_ line: LyricLine, at time: TimeInterval) -> Double {
        guard line.endTime > line.startTime else {
            return time >= line.endTime ? 1 : 0
        }
        let p = (time - line.startTime) / (line.endTime - line.startTime)
        return min(max(p, 0), 1)
    }

    /// Progress (0...1) of a single word segment at `time`.
    public func segmentProgress(_ seg: LyricSegment, at time: TimeInterval) -> Double {
        guard seg.endTime > seg.startTime else {
            return time >= seg.endTime ? 1 : 0
        }
        let p = (time - seg.startTime) / (seg.endTime - seg.startTime)
        return min(max(p, 0), 1)
    }
}
