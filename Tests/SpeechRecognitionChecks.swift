import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

@main struct SpeechRecognitionChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let options = SpeechRecognitionOptions(contextualStrings: ["  熊本 ", "熊本", "", "Piano", "piano", String(repeating: "长", count: 65)] + (0..<150).map { "地名\($0)" })
        precondition(options.contextualStrings.count == 100 && options.contextualStrings.prefix(2) == ["熊本", "Piano"])
        precondition(!EnhancedSpeechModelAvailability.notInstalled.isDownloading && EnhancedSpeechModelAvailability.notInstalled.canPrepare)
        precondition(EnhancedSpeechModelAvailability.downloading.isDownloading && !EnhancedSpeechModelAvailability.downloading.canPrepare)
        func word(_ text: String, _ start: Double, _ duration: Double) -> SpeechSegment { SpeechSegment(text: text, timestamp: start, duration: duration) }
        var accumulator = SpeechTranscriptAccumulator()
        accumulator.apply(SpeechPassage(start: 0, end: 3, words: [word("海便的", 0, 1), word("风，", 1, 1), word("好温柔。", 2, 1)], isFinal: false, hasTiming: true))
        accumulator.apply(SpeechPassage(start: 0, end: 1, words: [word("海边的", 0, 1)], isFinal: true, hasTiming: true))
        precondition(accumulator.snapshot.text == "海边的风，好温柔。", "A revision of the head preserves an earlier passage's unaffected tail")
        accumulator.apply(SpeechPassage(start: 1, end: 3, words: [word("风，", 1, 1), word("很温柔。", 2, 1)], isFinal: true, hasTiming: true))
        accumulator.apply(SpeechPassage(start: 0, end: 1, words: [word("海便", 0, 1)], isFinal: false, hasTiming: true))
        precondition(accumulator.snapshot.text == "海边的风，很温柔。" && accumulator.hasFinalResult && accumulator.hasFinalTiming)
        accumulator.apply(SpeechPassage(start: 3, end: 4, words: [word(" We love it! ", 3, 1)], isFinal: true, hasTiming: true))
        accumulator.apply(SpeechPassage(start: 0, end: 4, words: [], isFinal: true, hasTiming: true))
        let snapshot = accumulator.snapshot
        precondition(snapshot.text == "海边的风，很温柔。 We love it!")
        precondition(snapshot.words.map(\.text).joined() == snapshot.text, "Word timing ranges preserve punctuation, spaces, and trimmed boundaries")
        for word in snapshot.words { precondition((snapshot.text as NSString).substring(with: word.utf16Range) == word.text) }
        let phrases = SpeechCapture.shortPhrases(from: snapshot.words, transcript: snapshot.text)
        precondition(phrases.map(\.text).joined() == snapshot.text)
        var unconfirmed = SpeechTranscriptAccumulator()
        unconfirmed.apply(SpeechPassage(start: 0, end: 1, words: [word("时间缺失也保留文字", 0, 1)], isFinal: true, hasTiming: false))
        precondition(unconfirmed.hasFinalResult && !unconfirmed.hasFinalTiming)
        print("PASS vocabulary limits, final/volatile range revisions, final protection, punctuation, UTF-16, phrases, and separate final text/timing state")

        for format in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let pcmFormat = AVAudioFormat(commonFormat: format, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
                let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 2048)!
                pcm.frameLength = 2048
                for channel in 0..<2 {
                    let pointer = interleaved ? 0 : channel, offset = interleaved ? channel : 0
                    for frame in 0..<2048 {
                        let index = frame * pcm.stride + offset
                        if let data = pcm.floatChannelData { data[pointer][index] = channel == 1 ? 0.0002 : 0 }
                        if let data = pcm.int16ChannelData { data[pointer][index] = channel == 1 ? 7 : 0 }
                        if let data = pcm.int32ChannelData { data[pointer][index] = channel == 1 ? 429_497 : 0 }
                    }
                }
                let rms = SpeechAudioMeasurement.rms(pcm)
                precondition(rms > SpeechAudioMeasurement.minimumAudibleRMS && rms < 0.0015, "Quiet active second channel must be accepted for every PCM format")
            }
        }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")),
           let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)]) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            for (level, expected) in [(Float(0), false), (0.00009, false), (0.00011, true)] {
                let stream = AsyncStream<AnalyzerInput>.makeStream()
                let bridge = try ModernSpeechAudioInput(inputFormat: format, analyzerFormat: target, continuation: stream.continuation, meter: { _ in })
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!; pcm.frameLength = 2048
                for frame in 0..<2048 { pcm.floatChannelData![0][frame] = level }
                bridge.append(pcm); bridge.finish()
                for await _ in stream.stream {} // drain the selected analyzer format before releasing its buffers
                precondition(bridge.hasAudibleInput == expected, "Near-zero input gate must preserve quiet audio and reject all-zero buffers")
            }
        }
        #endif
        print("PASS float/int16/int32, interleaved active-channel measurement, quiet audio, and all-zero input boundary")

        let factory = SpeechInputFactory.make()
        await factory.refreshEnhancedModelAvailability()
        print("MODEL \(factory.enhancedModelAvailability.message)")
        if ProcessInfo.processInfo.environment["YINGSHU_SPEECH_PREPARE"] == "1", factory.enhancedModelAvailability.canPrepare {
            var lastPrinted = -1.0
            let observation = factory.changes.sink {
                if let progress = factory.enhancedModelDownloadProgress, progress - lastPrinted >= 0.05 || progress >= 1 {
                    lastPrinted = progress; print("DOWNLOAD progress=\(progress)")
                }
            }
            print("DOWNLOAD explicit diagnostic installation requested once, no microphone or new authorization")
            do { try await factory.prepareEnhancedModel(); print("DOWNLOAD completed: \(factory.enhancedModelAvailability.message)") }
            catch { print("DOWNLOAD failed: \(error.localizedDescription)"); throw error }
            withExtendedLifetime(observation) {}
        }
        guard ProcessInfo.processInfo.environment["YINGSHU_SPEECH_QUALITY"] == "1" else { return }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), factory.enhancedModelAvailability == .installed {
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YINGSHU_SPEECH_FIXTURES"]!)
            let reservationsBefore = await AssetInventory.reservedLocales
            var records: [[String: Any]] = []
            for fixture in ["ordinary", "places"] {
                let expected = try String(contentsOf: directory.appendingPathComponent(fixture + ".txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = directory.appendingPathComponent(fixture + ".aiff")
                for contextual in [false, true] {
                    let modern = ModernSpeechCapture()
                    modern.configure(options: SpeechRecognitionOptions(contextualStrings: contextual ? ["熊本", "阿苏", "白川水源", "上色见熊野座神社"] : []))
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = try await modern.transcribeFile(url: url)
                    precondition(!result.isEmpty && modern.hasFinalResult, "Real modern recognizer must return finalized words")
                    precondition(modern.wordSegments.map(\.text).joined() == result)
                    let record: [String: Any] = ["backend": "SpeechTranscriber", "fixture": fixture, "contextualStrings": contextual,
                        "reference": expected, "transcript": result, "cer": cer(expected, result), "seconds": ProcessInfo.processInfo.systemUptime - start,
                        "hasFinalResult": modern.hasFinalResult, "hasFinalTiming": modern.hasFinalTiming, "wordCount": modern.wordSegments.count]
                    records.append(record)
                    print(String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!)
                }
                // No new legacy authorization prompt: only compare if this diagnostic already has Speech permission.
                if SFSpeechRecognizer.authorizationStatus() == .authorized {
                    let legacy = SpeechCapture()
                    legacy.configure(options: SpeechRecognitionOptions(contextualStrings: ["熊本", "阿苏", "白川水源", "上色见熊野座神社"]))
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = try await legacy.transcribeFile(url: url, requireOnDevice: true)
                    let record: [String: Any] = ["backend": "SFSpeechRecognizer-on-device", "fixture": fixture, "reference": expected,
                        "transcript": result, "cer": cer(expected, result), "seconds": ProcessInfo.processInfo.systemUptime - start,
                        "hasFinalResult": legacy.hasFinalResult, "hasFinalTiming": legacy.hasFinalTiming]
                    records.append(record)
                    print(String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!)
                } else { print("SKIP legacy quality comparison: this diagnostic has no existing Speech authorization; no permission requested") }
            }
            // Feed 48 kHz PCM through exactly the serial copy/resampling bridge used by live capture.
            // This uses a generated file, and never opens an audio input device.
            let matched = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))!
            let transcriber = SpeechTranscriber(locale: matched, preset: .timeIndexedProgressiveTranscription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let audio = try AVAudioFile(forReading: directory.appendingPathComponent("ordinary-48k.wav"))
            let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: audio.processingFormat)!
            let stream = AsyncStream<AnalyzerInput>.makeStream()
            let bridge = try ModernSpeechAudioInput(inputFormat: audio.processingFormat, analyzerFormat: target, continuation: stream.continuation, meter: { _ in })
            let resultsTask = Task { () throws -> String in
                var text = ""
                for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
                return text
            }
            try await analyzer.start(inputSequence: stream.stream)
            while audio.framePosition < audio.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1024)!
                try audio.read(into: buffer); bridge.append(buffer)
            }
            bridge.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let convertedText = try await resultsTask.value
            let convertedReference = try String(contentsOf: directory.appendingPathComponent("ordinary.txt"), encoding: .utf8)
            precondition(bridge.hasAudibleInput && cer(convertedReference, convertedText) < 0.1, "The live PCM conversion path preserves intelligible Chinese")
            print("PASS live 48kHz PCM bridge -> \(target.sampleRate)Hz -> real SpeechAnalyzer, CER=\(cer(convertedReference, convertedText)), no microphone")

            for variant in ["int16", "quiet-float"] {
                let source = try AVAudioFile(forReading: directory.appendingPathComponent("ordinary-48k.wav"),
                                             commonFormat: variant == "int16" ? .pcmFormatInt16 : .pcmFormatFloat32, interleaved: false)
                var gain: Float = 1
                if variant == "quiet-float" {
                    var peakRMS: Float = 0
                    while source.framePosition < source.length {
                        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 1024)!
                        try source.read(into: buffer); peakRMS = max(peakRMS, SpeechAudioMeasurement.rms(buffer))
                    }
                    precondition(peakRMS > 0); gain = 0.0008 / peakRMS; source.framePosition = 0
                }
                let recognizer = SpeechTranscriber(locale: matched, preset: .timeIndexedProgressiveTranscription)
                let analysis = SpeechAnalyzer(modules: [recognizer])
                let sequence = AsyncStream<AnalyzerInput>.makeStream()
                let input = try ModernSpeechAudioInput(inputFormat: source.processingFormat, analyzerFormat: target,
                                                       continuation: sequence.continuation, meter: { _ in })
                let resultReader = Task { () throws -> String in
                    var text = ""
                    for try await result in recognizer.results where result.isFinal { text += String(result.text.characters) }
                    return text
                }
                try await analysis.start(inputSequence: sequence.stream)
                var maxInputRMS: Float = 0
                while source.framePosition < source.length {
                    let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 1024)!
                    try source.read(into: buffer)
                    if variant == "quiet-float" {
                        for channel in 0..<Int(buffer.format.channelCount) {
                            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] *= gain }
                        }
                    }
                    maxInputRMS = max(maxInputRMS, SpeechAudioMeasurement.rms(buffer)); input.append(buffer)
                }
                input.finish(); try await analysis.finalizeAndFinishThroughEndOfInput()
                let text = try await resultReader.value
                precondition(input.hasAudibleInput && !text.isEmpty && cer(convertedReference, text) < 0.1)
                if variant == "quiet-float" { precondition(maxInputRMS < 0.0015 && maxInputRMS > 0.0001, "The former gate would discard this entire quiet recording") }
                print("PASS actual \(variant) PCM -> modern live bridge -> real Chinese recognizer, CER=\(cer(convertedReference, text)), maxRMS=\(maxInputRMS), no microphone")
            }

            let cancelling = ModernSpeechCapture()
            let cancelTask = Task { try await cancelling.transcribeFile(url: directory.appendingPathComponent("places.aiff")) }
            try await Task.sleep(nanoseconds: 1_000_000)
            cancelTask.cancel()
            do { _ = try await cancelTask.value; preconditionFailure("Cancelled recognition must not return a successful result") }
            catch is CancellationError {} catch { preconditionFailure("Unexpected cancellation error: \(error)") }
            try await Task.sleep(nanoseconds: 100_000_000)
            precondition(cancelling.transcript.isEmpty && !cancelling.isRecognizingFile, "Cancelled session cannot receive late text")
            let recovered = try await cancelling.transcribeFile(url: directory.appendingPathComponent("ordinary.aiff"))
            precondition(!recovered.isEmpty && cancelling.hasFinalResult, "The recognizer recovers after cancellation")
            let hybrid = SpeechInputFactory.make()
            let abandoned = Task { try await hybrid.transcribeFile(url: directory.appendingPathComponent("places.aiff")) }
            try await Task.sleep(nanoseconds: 1_000_000)
            hybrid.cancel()
            let restarted = Task { try await hybrid.transcribeFile(url: directory.appendingPathComponent("ordinary.aiff")) }
            do { _ = try await abandoned.value; preconditionFailure("Abandoned hybrid session must end") } catch is CancellationError {} catch { preconditionFailure("Unexpected abandoned-session error: \(error)") }
            let restartedText = try await restarted.value
            precondition(!restartedText.isEmpty && hybrid.transcript == restartedText && hybrid.hasFinalResult,
                         "An older hybrid operation must not cancel or reset its replacement")
            print("PASS actual file cancellation, late-result isolation, hybrid immediate restart, and recovery without microphone access")
            print("PASS actual generated Mandarin file transcription; these CER results concern synthetic Tingting speech, not the user's accent/microphone")
            let output = directory.appendingPathComponent("quality-results.json")
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            // The test process has a separate diagnostic identity; do not leave its reservation behind.
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")),
               !reservationsBefore.contains(where: { $0.identifier == locale.identifier }) {
                await AssetInventory.release(reservedLocale: locale)
            }
        } else { print("SKIP real recognition: modern zh-CN assets are not installed; no automatic download or microphone access") }
        #endif
    }
    static func cer(_ reference: String, _ hypothesis: String) -> Double {
        func normalized(_ value: String) -> [Character] {
            Array(value.lowercased().filter { character in character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } })
        }
        let a = normalized(reference), b = normalized(hypothesis)
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, right) in b.enumerated() { current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)) }
            previous = current
        }
        return Double(previous[b.count]) / Double(a.count)
    }
}
