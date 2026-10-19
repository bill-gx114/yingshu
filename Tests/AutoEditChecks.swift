import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

@main struct AutoEditChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("YingShu-AutoEdit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let flat = temporary.appendingPathComponent("flat.png")
        let rich = temporary.appendingPathComponent("rich.png")
        try writePicture(to: flat, rich: false)
        try writePicture(to: rich, rich: true)
        let a = MediaClip(url: flat, name: "空白画面", kind: .image, duration: 4, sourceDuration: 30)
        let b = MediaClip(url: rich, name: "丰富画面", kind: .image, duration: 4, sourceDuration: 30)
        let duplicate = MediaClip(url: rich, name: "重复画面", kind: .image, duration: 4, sourceDuration: 30)
        let content = try await AutoEditEngine.plan(clips: [a, b, duplicate], captions: [], musicURL: nil, progress: { _, _ in })
        precondition(content.clips.map(\.id) == [a.id, b.id, duplicate.id], "Editing must retain identity and order")
        precondition(content.clips[1].duration > content.clips[0].duration + 0.4, "Real image content must change the preferred hold")
        precondition(content.clips[2].duration < content.clips[1].duration - 0.3, "A repeated Vision embedding should receive less time")
        precondition(content.clips.allSatisfy { (1.5...7).contains($0.duration) })
        precondition(content.estimatedBPM == nil && content.beatTimes.isEmpty)
        print("PASS image inference: flat=\(content.clips[0].duration), rich=\(content.clips[1].duration), repeated=\(content.clips[2].duration)")
        let repeatedPlan = try await AutoEditEngine.plan(clips: content.clips, captions: content.captions, musicURL: nil, progress: { _, _ in })
        precondition(repeatedPlan.clips == content.clips, "Repeated content analysis must not make durations drift")

        let pulse = temporary.appendingPathComponent("pulse.wav")
        let silence = temporary.appendingPathComponent("silence.wav")
        let tone = temporary.appendingPathComponent("tone.wav")
        let pulse90 = temporary.appendingPathComponent("pulse90.wav")
        let noise = temporary.appendingPathComponent("noise.wav")
        try writeAudio(to: pulse, kind: .pulse)
        try writeAudio(to: silence, kind: .silence)
        try writeAudio(to: tone, kind: .tone)
        try writeAudio(to: pulse90, kind: .pulse, bpm: 90)
        try writeAudio(to: noise, kind: .noise)
        let rhythm = try await AutoEditEngine.detectBeats(url: pulse)
        print("Measured pulse tempo=\(rhythm.bpm.map(String.init(describing:)) ?? "nil"), confidence=\(rhythm.confidence), onsets=\(rhythm.times.count)")
        precondition(rhythm.bpm.map { abs($0 - 120) < 4 } == true, "The PCM pulse train is actually 120 BPM")
        precondition(rhythm.times.count >= 15 && rhythm.confidence >= 0.64)
        precondition(rhythm.times.allSatisfy { time in
            let nearest = ((time - 0.1) / 0.5).rounded() * 0.5 + 0.1
            return abs(time - nearest) < 0.065
        }, "Returned cut points must be measured attacks, not a fabricated grid")
        let quiet = try await AutoEditEngine.detectBeats(url: silence)
        precondition(quiet.bpm == nil && quiet.times.isEmpty, "Silence must not produce a BPM")
        let sustained = try await AutoEditEngine.detectBeats(url: tone)
        precondition(sustained.bpm == nil && sustained.times.isEmpty, "A sustained tone has no drum attacks")
        let unstructured = try await AutoEditEngine.detectBeats(url: noise)
        precondition(unstructured.bpm == nil && unstructured.times.isEmpty, "Stationary noise must not be called a steady musical rhythm")
        let slower = try await AutoEditEngine.detectBeats(url: pulse90)
        precondition(slower.bpm.map { abs($0 - 90) < 3 } == true, "A different audio file must yield its measured tempo")
        let bounded = try await AutoEditEngine.detectBeats(url: pulse, maximumDuration: 3)
        precondition(bounded.analyzedDuration <= 3.01)
        print("PASS measured onset timing, silence, sustained tone, bounded audio analysis")

        let fastCut = try await AutoEditEngine.plan(clips: [a, b], captions: [], musicURL: pulse, progress: { _, _ in })
        let slowCut = try await AutoEditEngine.plan(clips: [a, b], captions: [], musicURL: pulse90, progress: { _, _ in })
        precondition(fastCut.estimatedBPM.map { abs($0 - 120) < 4 } == true && slowCut.estimatedBPM.map { abs($0 - 90) < 3 } == true)
        precondition(zip(fastCut.clips, slowCut.clips).contains { abs($0.duration - $1.duration) > 0.06 }, "Changing the music must change real cut points")
        let fastAgain = try await AutoEditEngine.plan(clips: fastCut.clips, captions: [], musicURL: pulse, progress: { _, _ in })
        precondition(fastAgain.clips == fastCut.clips, "Reapplying the same music must be stable")
        print("PASS actual 120/90 BPM music changes cut points; repeated planning stays stable")

        var locked = a
        locked.duration = 5.8; locked.trimStart = 0.2; locked.timingLocked = true
        let caption = Caption(clipID: b.id, start: 0.3, duration: 1,
                              text: "海边的风慢慢吹过来，那一刻我们什么都没有做，只想把眼前的光多留一会儿。", style: .note)
        let captioned = try await AutoEditEngine.plan(clips: [locked, b], captions: [caption], musicURL: pulse, progress: { _, _ in })
        precondition(captioned.clips[0] == locked, "Manual timing locks must remain exact")
        precondition(captioned.captions.count == 1 && captioned.captions[0].id == caption.id && captioned.captions[0].text == caption.text)
        precondition(captioned.captions[0].duration + 0.001 >= AutoEditEngine.readingDuration(caption.text), "Text must be given time to read")
        precondition(captioned.captions[0].start + captioned.captions[0].duration <= captioned.clips[1].duration + 0.001)
        precondition(captioned.estimatedBPM != nil)
        let cut = captioned.clips.totalDuration
        print("Captioned duration=\(captioned.clips[1].duration), final cut=\(cut), nearest onset=\(captioned.beatTimes.min(by: { abs($0 - cut) < abs($1 - cut) }) ?? -1), summary=\(captioned.summary)")
        precondition(captioned.beatTimes.contains { abs($0 - cut) < 0.04 }, "An unlocked cut should snap to an actual music attack")
        print("PASS locked timing, caption identity/text/readability, measured cut snapping")

        let firstText = Caption(clipID: a.id, start: 0, duration: 0.5, text: "这是第一句需要读完的文字。")
        let secondText = Caption(clipID: a.id, start: 0.8, duration: 0.5, text: "这是接下来另一句也需要读完的文字。")
        let sequential = try await AutoEditEngine.plan(clips: [a], captions: [firstText, secondText], musicURL: nil, progress: { _, _ in })
        precondition(sequential.captions[0].start + sequential.captions[0].duration <= sequential.captions[1].start + 0.001,
                     "Longer reading time must not create new overlapping photo captions")
        precondition(sequential.captions.allSatisfy { $0.duration + 0.001 >= AutoEditEngine.readingDuration($0.text) })

        let movie = temporary.appendingPathComponent("two-scenes.mp4")
        try await writeMovie(to: movie, first: flat, second: rich)
        let video = MediaClip(url: movie, name: "先空白后精彩", kind: .video, duration: 8, sourceDuration: 14, trimStart: 2, sourceStart: 2)
        let highlight = try await AutoEditEngine.plan(clips: [video], captions: [], musicURL: nil, progress: { _, _ in })
        precondition(highlight.clips[0].trimStart > 3, "Actual sampled video should select the richer later scene")
        precondition(highlight.clips[0].trimStart >= 2 && highlight.clips[0].trimStart + highlight.clips[0].duration <= 14.001)
        let videoText = Caption(clipID: video.id, start: 1.5, duration: 1.5, text: "这段文字对应的是原来的视频画面。")
        let withText = try await AutoEditEngine.plan(clips: [video], captions: [videoText], musicURL: pulse90, progress: { _, _ in })
        precondition(withText.clips[0].trimStart == video.trimStart, "Captioned videos must keep the original source window")
        precondition(withText.captions[0].start == videoText.start && withText.captions[0].text == videoText.text)
        precondition(withText.clips[0].trimStart + withText.clips[0].duration <= 14.001)
        var lockedVideo = video; lockedVideo.timingLocked = true
        let frozen = try await AutoEditEngine.plan(clips: [lockedVideo], captions: [videoText], musicURL: pulse, progress: { _, _ in })
        precondition(frozen.clips == [lockedVideo] && frozen.captions == [videoText])
        print("PASS sequential caption reading, actual video highlight sampling, source boundaries, captioned video window, locked video")

        let cancelled = Task {
            try await AutoEditEngine.plan(clips: Array(repeating: b, count: 20).enumerated().map { index, clip in
                var value = clip; value.id = UUID(); value.name = "\(index)"; return value
            }, captions: [], musicURL: pulse, progress: { _, _ in })
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError { print("PASS cancellation") }
        let probe = StartProbe()
        let inFlight = Task {
            try await AutoEditEngine.plan(clips: (0..<50).map { index in
                var copy = b; copy.id = UUID(); copy.name = "\(index)"; return copy
            }, captions: [], musicURL: pulse, progress: { _, _ in probe.mark() })
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        inFlight.cancel()
        do { _ = try await inFlight.value; preconditionFailure("In-flight cancellation ignored") }
        catch is CancellationError { precondition(probe.hasStarted); print("PASS cancellation during actual image analysis") }
        print("PASS: real Vision content/duplicate scoring, actual PCM rhythm, reading, locks, and cancellation")
    }

    private static func writePicture(to url: URL, rich: Bool) throws {
        let side = 512
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StudioError.message("Cannot create test image")
        }
        context.setFillColor(CGColor(gray: 0.45, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if rich {
            for y in 0..<16 {
                for x in 0..<16 {
                    context.setFillColor(CGColor(red: CGFloat((x * 37 + y * 13) % 255) / 255,
                                                 green: CGFloat((x * 17 + y * 47) % 255) / 255,
                                                 blue: CGFloat((x * 67 + y * 7) % 255) / 255, alpha: 1))
                    context.fillEllipse(in: CGRect(x: x * 32, y: y * 32, width: 26 + (x % 4), height: 27))
                }
            }
        }
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw StudioError.message("Cannot write test image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.message("Test PNG failed") }
    }

    private enum AudioKind { case pulse, silence, tone, noise }
    private static func writeAudio(to url: URL, kind: AudioKind, bpm: Double = 120) throws {
        let rate = 22050.0, length = 12.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let count = Int(rate * length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        var randomState: UInt32 = 10717
        for frame in 0..<count {
            let time = Double(frame) / rate
            var sample = 0.0
            switch kind {
            case .silence: break
            case .tone: sample = 0.25 * sin(2 * .pi * 440 * time)
            case .noise:
                randomState = 1_664_525 &* randomState &+ 1_013_904_223
                sample = (Double(randomState) / Double(UInt32.max) * 2 - 1) * 0.25
            case .pulse:
                let since = (time - 0.1).truncatingRemainder(dividingBy: 60 / bpm)
                if time >= 0.1 && since >= 0 && since < 0.035 {
                    let envelope = exp(-since * 95)
                    sample = envelope * (0.55 * sin(2 * .pi * 90 * since) + 0.30 * sin(2 * .pi * 1500 * since))
                }
            }
            buffer.floatChannelData![0][frame] = Float(sample)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func writeMovie(to url: URL, first: URL, second: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: 160, AVVideoHeightKey: 160])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 160])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError.message("Test video writer failed") }
        writer.startSession(atSourceTime: .zero)
        let images = [first, second].map { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL($0 as CFURL, nil)!, 0, nil)! }
        for frame in 0..<140 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 160, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel) == kCVReturnSuccess,
                  let pixel else { throw StudioError.message("Test video buffer failed") }
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 160, height: 160, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(images[frame < 70 ? 0 : 1], in: CGRect(x: 0, y: 0, width: 160, height: 160))
            if frame >= 70 {
                context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1))
                context.fillEllipse(in: CGRect(x: (frame * 3) % 130, y: 35, width: 22, height: 22))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? StudioError.message("Test video append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StudioError.message("Test video did not finish") }
    }

    private final class StartProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        func mark() { lock.lock(); started = true; lock.unlock() }
        var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    }
}
