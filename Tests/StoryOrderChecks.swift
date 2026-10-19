import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

@main struct StoryOrderChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("YingShu-StoryOrder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let day = ISO8601DateFormatter().date(from: "2026-10-17T10:00:00+08:00")!
        func clip(_ filename: String, time: Date?, created: Date? = nil, order: Int? = nil) -> MediaClip {
            MediaClip(url: temporary.appendingPathComponent(filename), name: "显示名与文件名无关", kind: .image,
                      duration: 4, sourceDuration: 30, capturedAt: time, fileCreatedAt: created, importOrder: order)
        }
        let late = clip("IMG_10.png", time: day.addingTimeInterval(86400), created: day.addingTimeInterval(-86400), order: 0)
        let early = clip("IMG_2.png", time: day, order: 3)
        let tie = clip("IMG_3.png", time: day, order: 1)
        let fallback = clip("IMG_4.png", time: nil, created: day.addingTimeInterval(3600), order: 2)
        let unknown = clip("IMG_5.png", time: nil, order: 4)
        let input = [late, early, unknown, fallback, tie]
        let chronological = try await StoryOrderEngine.arrange(clips: input, mode: .chronological, progress: { _, _ in })
        precondition(chronological.clips.map(\.id) == [tie.id, early.id, fallback.id, late.id, unknown.id])
        precondition(chronological.summary.contains("文件创建时间") && chronological.summary.contains("没有可用时间"))
        precondition(chronological.clips.first(where: { $0.id == late.id }) == late, "Capture time must outrank an earlier file creation date")
        let manual = try await StoryOrderEngine.arrange(clips: input, mode: .manual, progress: { _, _ in })
        precondition(manual.clips == input)
        let imported = try await StoryOrderEngine.arrange(clips: input, mode: .imported, progress: { _, _ in })
        precondition(imported.clips.map(\.id) == [late.id, tie.id, fallback.id, early.id, unknown.id])
        let filename = try await StoryOrderEngine.arrange(clips: input, mode: .filename, progress: { _, _ in })
        precondition(filename.clips.map(\.id) == [early.id, tie.id, fallback.id, unknown.id, late.id], "Use real filenames and numeric sorting")
        print("PASS capture-time priority, file-creation fallback disclosure, stable ties, filenames, import order, manual identity")

        let flat = temporary.appendingPathComponent("00-flat.png")
        let richA = temporary.appendingPathComponent("01-rich.png")
        let richB = temporary.appendingPathComponent("03-varied.png")
        let calm = temporary.appendingPathComponent("04-calm.png")
        try writeImage(flat, style: 0)
        try writeImage(richA, style: 1)
        try writeImage(richB, style: 2)
        try writeImage(calm, style: 3)
        let paths = [flat, richA, richA, richB, calm]
        var event = paths.enumerated().map { index, url -> MediaClip in
            MediaClip(url: url, name: "画面\(index)", kind: .image, duration: Double(index + 2), sourceDuration: 30,
                      trimStart: 0.1, timingLocked: index == 2 ? true : nil,
                      capturedAt: day.addingTimeInterval(Double(index) * 20), importOrder: index)
        }
        let laterEvent = MediaClip(url: richB, name: "两小时后", kind: .image, duration: 4, sourceDuration: 30,
                                   capturedAt: day.addingTimeInterval(7200), importOrder: 5)
        let nextDay = MediaClip(url: richA, name: "第二天", kind: .image, duration: 4, sourceDuration: 30,
                               capturedAt: day.addingTimeInterval(86400), importOrder: 6)
        let missingTime = MediaClip(url: calm, name: "无日期", kind: .image, duration: 4, sourceDuration: 30, importOrder: 7)
        event += [laterEvent, nextDay, missingTime]
        let story = try await StoryOrderEngine.arrange(clips: event, mode: .story, progress: { _, _ in })
        precondition(story.clips.map(\.id) != event.map(\.id), "Actual visual content should affect this story proposal")
        precondition(story.clips.first?.id != event[0].id, "A blank frame should not outrank the informative establishing picture")
        let original = Dictionary(uniqueKeysWithValues: event.map { ($0.id, $0) })
        precondition(story.clips.count == event.count && story.clips.allSatisfy { original[$0.id] == $0 }, "Only order may change")
        precondition(Set(story.clips.prefix(5).map(\.id)) == Set(event.prefix(5).map(\.id)))
        precondition(story.clips[5].id == laterEvent.id && story.clips[6].id == nextDay.id && story.clips[7].id == missingTime.id,
                     "Separate events, days, and unknown-time groups must not interleave")
        let firstDuplicate = story.clips.firstIndex { $0.id == event[1].id }!
        let secondDuplicate = story.clips.firstIndex { $0.id == event[2].id }!
        precondition(abs(firstDuplicate - secondDuplicate) > 1, "Actual Vision similarity should help avoid adjacent duplicate views")
        precondition(!story.summary.contains("暂未完成"), "These real images must actually finish Vision inference")
        let again = try await StoryOrderEngine.arrange(clips: story.clips, mode: .story, progress: { _, _ in })
        precondition(again.clips == story.clips, "Repeated planning must remain stable")
        print("PASS actual Vision narrative changes, duplicate separation, day/event boundaries, exact clip preservation, repeated stability")

        let movie = temporary.appendingPathComponent("live-motion.mp4")
        try await writeMovie(movie, imageURL: richB)
        let live = MediaClip(url: movie, name: "实况照片", kind: .video, duration: 1, sourceDuration: 1,
                             capturedAt: day.addingTimeInterval(50), importOrder: 8,
                             livePhotoStillURL: richA, livePhotoAssetID: "synthetic-live-pair")
        let mixed = try await StoryOrderEngine.arrange(clips: Array(event.prefix(5)) + [live], mode: .story, progress: { _, _ in })
        precondition(mixed.clips.count == 6 && mixed.clips.filter { $0.id == live.id }.count == 1)
        precondition(mixed.clips.first(where: { $0.id == live.id }) == live, "A Live Photo stays one intact clip with its still companion")
        precondition(!mixed.summary.contains("暂未完成"), "The movie and still companion must actually be analyzed")
        let pairedNames = try await StoryOrderEngine.arrange(clips: [event[3], live], mode: .filename, progress: { _, _ in })
        precondition(pairedNames.clips.first?.id == live.id, "A Live Photo uses its displayed still filename instead of an unrelated MOV name")
        var plainVideo = live
        plainVideo.id = UUID(); plainVideo.name = "普通视频"; plainVideo.livePhotoStillURL = nil; plainVideo.livePhotoAssetID = nil
        plainVideo.capturedAt = day.addingTimeInterval(55); plainVideo.importOrder = 9
        let withPlainMovie = try await StoryOrderEngine.arrange(clips: Array(event.prefix(5)) + [live, plainVideo], mode: .story, progress: { _, _ in })
        precondition(withPlainMovie.clips.count == 7 && withPlainMovie.clips.first(where: { $0.id == plainVideo.id }) == plainVideo)
        precondition(!withPlainMovie.summary.contains("暂未完成"), "Ordinary movie frames must also finish actual Vision inference")
        print("PASS actual video sampling and intact Live Photo companion fields")

        var undated = Array(event.prefix(5))
        for index in undated.indices { undated[index].capturedAt = nil; undated[index].fileCreatedAt = nil; undated[index].importOrder = nil }
        let noTime = try await StoryOrderEngine.arrange(clips: undated, mode: .story, progress: { _, _ in })
        let noTimeAgain = try await StoryOrderEngine.arrange(clips: noTime.clips, mode: .story, progress: { _, _ in })
        precondition(noTimeAgain.clips == noTime.clips)
        precondition(noTime.summary.contains("没有可用时间"))
        let earlyCancel = Task { try await StoryOrderEngine.arrange(clips: event, mode: .story, progress: { _, _ in }) }
        earlyCancel.cancel()
        do { _ = try await earlyCancel.value; preconditionFailure("Preflight cancellation ignored") }
        catch is CancellationError { }
        let probe = StartProbe()
        let active = Task {
            try await StoryOrderEngine.arrange(clips: (0..<80).map { index in
                var value = event[index % 5]; value.id = UUID(); value.importOrder = index; return value
            }, mode: .story, progress: { progress, _ in if progress >= 0.05 { probe.mark() } })
        }
        try await Task.sleep(nanoseconds: 35_000_000)
        active.cancel()
        do { _ = try await active.value; preconditionFailure("Analysis cancellation ignored") }
        catch is CancellationError { precondition(probe.started) }
        print("PASS unknown-time stability and cancellation before/during actual analysis")
    }

    private static func writeImage(_ url: URL, style: Int) throws {
        let width = 512, height = 384
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.42, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if style == 1 || style == 2 {
            for y in 0..<12 {
                for x in 0..<16 {
                    let r = CGFloat((x * (style == 1 ? 37 : 83) + y * 13) % 255) / 255
                    context.setFillColor(CGColor(red: r, green: CGFloat((x * 17 + y * 47) % 255) / 255,
                                                 blue: CGFloat((x * 67 + y * (style == 1 ? 7 : 71)) % 255) / 255, alpha: 1))
                    if style == 1 { context.fillEllipse(in: CGRect(x: x * 32, y: y * 32, width: 27, height: 26)) }
                    else { context.fill(CGRect(x: x * 32, y: y * 32, width: 27, height: 28)) }
                }
            }
        } else if style == 3 {
            for y in 0..<height {
                let fraction = CGFloat(y) / CGFloat(height)
                context.setFillColor(CGColor(red: 0.2 + fraction * 0.3, green: 0.3 + fraction * 0.4, blue: 0.65, alpha: 1))
                context.fill(CGRect(x: 0, y: y, width: width, height: 1))
            }
            context.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.4, alpha: 1))
            context.fillEllipse(in: CGRect(x: 360, y: 220, width: 70, height: 70))
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.message("Test PNG failed") }
    }

    private static func writeMovie(_ url: URL, imageURL: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: 128, AVVideoHeightKey: 96])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError.message("Test video failed") }
        writer.startSession(atSourceTime: .zero)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(imageURL as CFURL, nil)!, 0, nil)!
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 128, 96, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel) == kCVReturnSuccess,
                  let pixel else { throw StudioError.message("Test pixel failed") }
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 128, height: 96, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 96))
            context.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: frame * 8, y: 24, width: 20, height: 20))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? StudioError.message("Test movie append failed")
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StudioError.message("Test movie incomplete") }
    }

    private final class StartProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); value = true; lock.unlock() }
        var started: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
