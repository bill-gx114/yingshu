import Foundation

/// Audio time and movie time are different clocks: the movie can pause or buffer while speech continues.
struct PlaybackMoment: Equatable {
    var audioTime: Double
    var clipID: UUID
    var offset: Double
}

struct DictationWord {
    var text: String
    var timestamp: Double
    var duration: Double
}

enum DictationAlignment {
    static func captions(words: [DictationWord], moments: [PlaybackMoment], clips: [MediaClip], style: CaptionStyle) -> [Caption] {
        guard !moments.isEmpty else { return [] }
        let clipMap = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        struct Phrase {
            var clipID: UUID
            var start: Double
            var end: Double
            var text: String
            var audioEnd: Double
        }
        var phrases: [Phrase] = []
        for word in words where !word.text.isEmpty {
            let time = word.timestamp.isFinite ? max(0, word.timestamp) : 0
            let length = word.duration.isFinite ? max(0, word.duration) : 0
            guard let start = location(at: time, moments: moments), let clip = clipMap[start.clipID] else { continue }
            let end = location(at: time + length, moments: moments)
            let localEnd = end?.clipID == start.clipID ? (end?.offset ?? start.offset) : clip.duration
            if let last = phrases.last, last.clipID == start.clipID,
               time - last.audioEnd < 0.8, last.text.count < 36,
               last.text.last.map({ !"。！？!?；;\n".contains($0) }) ?? true {
                phrases[phrases.count - 1].text += word.text
                phrases[phrases.count - 1].end = max(last.end, localEnd)
                phrases[phrases.count - 1].audioEnd = time + length
            } else {
                phrases.append(Phrase(clipID: start.clipID, start: start.offset, end: max(start.offset, localEnd), text: word.text, audioEnd: time + length))
            }
        }
        return phrases.compactMap { phrase in
            guard let clip = clipMap[phrase.clipID] else { return nil }
            let text = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let reading = min(8, Double(text.count) / 6)
            let duration = min(clip.duration, max(2.2, phrase.end - phrase.start + 0.3, reading))
            let start = max(0, min(phrase.start - 0.18, clip.duration - duration))
            return Caption(clipID: clip.id, start: start, duration: duration, text: text, style: style)
        }
    }

    static func location(at audioTime: Double, moments: [PlaybackMoment]) -> PlaybackMoment? {
        guard let first = moments.first else { return nil }
        if audioTime <= first.audioTime { return first }
        var low = 0, high = moments.count
        while low < high {
            let mid = (low + high) / 2
            if moments[mid].audioTime <= audioTime { low = mid + 1 } else { high = mid }
        }
        let before = moments[max(0, low - 1)]
        guard low < moments.count else { return before }
        let after = moments[low]
        guard before.clipID == after.clipID, after.audioTime > before.audioTime else { return before }
        let fraction = max(0, min(1, (audioTime - before.audioTime) / (after.audioTime - before.audioTime)))
        return PlaybackMoment(audioTime: audioTime, clipID: before.clipID, offset: before.offset + (after.offset - before.offset) * fraction)
    }
}
