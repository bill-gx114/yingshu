import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw StudioError.message(message) }
}

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var quarterTime: Double?
    private var last = -1.0
    private var invalid = false
    let started = ProcessInfo.processInfo.systemUptime
    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        if !value.isFinite || value < last || value < 0 || value > 1 { invalid = true }
        last = value
        if value >= 0.25 && quarterTime == nil { quarterTime = ProcessInfo.processInfo.systemUptime - started }
    }
    func verify() throws {
        lock.lock(); defer { lock.unlock() }
        try require(!invalid && last == 1, "Progress regressed, was invalid, or did not finish")
    }
}

@main struct MediaSmoke {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); Foundation.exit(1) }
    }

    @MainActor private static func run() async throws {
        let folder = URL(fileURLWithPath: "/tmp/yingshu-media-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try createPhotos(in: folder)
        var jpeg = try await MediaEngine.inspect(url: folder.appendingPathComponent("oriented.jpg"))
        var heic = try await MediaEngine.inspect(url: folder.appendingPathComponent("oriented.heic"))
        try require(jpeg.kind == .image && heic.kind == .image && heic.duration == 4, "Photo classification/default duration failed")
        for photo in [jpeg, heic] {
            guard let image = await MediaEngine.thumbnail(for: photo),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw StudioError.message("Photo thumbnail missing") }
            try require(cg.width < cg.height, "EXIF rotation was not applied to \(photo.url.lastPathComponent)")
            // The encoded source has red/green above blue/yellow. EXIF=6 rotates it clockwise.
            try writePNG(cg, to: folder.appendingPathComponent("thumbnail-\(photo.url.lastPathComponent).png"))
            let corner = rgba(cg, x: 0.2, y: 0.2)
            try require(corner[2] > 0.7 && corner[0] < 0.25, "EXIF rotation or mirroring is wrong: \(corner)")
        }
        print("PASS: JPEG and HEIC EXIF orientation, image classification")
        var video = try await MediaEngine.inspect(url: folder.appendingPathComponent("source.mp4"))
        try require(video.kind == .video, "MP4 was misclassified as a photo")
        let tail = try await MediaEngine.inspect(url: folder.appendingPathComponent("audio-tail.mp4"))
        try require(abs(tail.duration - 1) < 0.05, "Audio tail was incorrectly counted as video: \(tail.duration)")
        let delayed = try await MediaEngine.inspect(url: folder.appendingPathComponent("delayed.mp4"))
        let delayedTrack = try await AVURLAsset(url: delayed.url).loadTracks(withMediaType: .video).first!
        let delayedRange = try await delayedTrack.load(.timeRange)
        let mediaSegments = try await delayedTrack.load(.segments).filter { !$0.isEmpty }
        let firstPicture = mediaSegments.map { $0.timeMapping.target.start.seconds }.min() ?? delayedRange.start.seconds
        try require(firstPicture > 0.2, "Fixture did not actually delay the picture")
        try require(abs(delayed.trimStart - firstPicture) < 0.001, "Leading empty edit was retained")
        try require(delayed.sourceStart == firstPicture, "Source start editing constraint was lost")
        try require(abs(delayed.duration - 3) < 0.001, "Leading empty edit was counted in clip duration")
        let short = try await MediaEngine.inspect(url: folder.appendingPathComponent("short.mp4"))
        try require(short.duration >= 1.0 / 30 - 0.001 && short.duration < 0.1, "Two-frame video was rejected or extended")
        var rotated = try await MediaEngine.inspect(url: folder.appendingPathComponent("rotated.mp4"))
        guard let rotatedThumbnail = await MediaEngine.thumbnail(for: rotated) else { throw StudioError.message("Rotated video thumbnail missing") }
        try require(rotatedThumbnail.size.width < rotatedThumbnail.size.height, "Video rotation transform was not respected")
        print("PASS: video classification, audio tail, nonzero track start, 2-frame video, rotation")

        jpeg.duration = 1.2; heic.duration = 1.2
        video.duration = 1.4; video.trimStart = 0.5
        rotated.duration = 1.0
        let longText = String(repeating: "那天我们沿着海岸慢慢走，记住了风吹过的声音。", count: 9)
        let captions = [
            Caption(clipID: heic.id, start: 0, duration: 0.8, text: "第一段：手机照片的方向应该正确\n今天的风，刚刚好。", style: .subtitle),
            Caption(clipID: video.id, start: 0.15, duration: 0.8, text: longText, style: .sticker),
            Caption(clipID: video.id, start: 0.15, duration: 0.8, text: "同一画面，第二张贴纸也不能盖住第一张。", style: .sticker),
            Caption(clipID: video.id, start: 0.15, duration: 0.8, text: "这是一条同时出现的字幕，用来验证文字互相避让。", style: .subtitle),
            Caption(clipID: video.id, start: 0.15, duration: 0.8, text: "手记 · 不丢掉自己的感受", style: .note),
            Caption(clipID: rotated.id, start: 0.1, duration: 0.7, text: "最后一段：手机竖屏视频", style: .note)
        ]
        for format in VideoFormat.allCases {
            let active = captions.filter { $0.clipID == video.id }
            let layers = MediaEngine.renderedCaptions(active, canvas: format.size)
            try require(layers.count == active.count, "Caption disappeared during overlap layout")
            for (index, layer) in layers.enumerated() {
                try require(CGRect(origin: .zero, size: format.size).contains(layer.frame), "Long caption escaped canvas")
                for other in layers.dropFirst(index + 1) { try require(!layer.frame.intersects(other.frame), "Caption cards overlap") }
            }
            let output = folder.appendingPathComponent(format == .landscape ? "result.mp4" : format == .portrait ? "portrait.mp4" : "square.mp4")
            let probe = ProgressProbe()
            try await MediaEngine.export(settings: ExportSettings(clips: [heic, video, rotated], captions: captions, format: format,
                musicURL: folder.appendingPathComponent("short-music.wav"), musicVolume: 0.3, outputURL: output)) { probe.record($0) }
            try probe.verify()
            try await verifyMovie(output, size: format.size, duration: 3.6, audio: true)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output)); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let (frame, _) = try await generator.image(at: CMTime(seconds: 0.95, preferredTimescale: 600))
            let (rotatedFrame, _) = try await generator.image(at: CMTime(seconds: 3.4, preferredTimescale: 600))
            if format == .portrait {
                let pixel = rgba(frame, x: 0.2, y: 0.2)
                try require(pixel[2] > 0.65 && pixel[0] < 0.3, "HEIC direction changed during export")
                let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: rotated.url)); sourceGenerator.appliesPreferredTrackTransform = true
                sourceGenerator.requestedTimeToleranceBefore = .zero; sourceGenerator.requestedTimeToleranceAfter = .zero
                let (sourceFrame, _) = try await sourceGenerator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600))
                try writePNG(sourceFrame, to: folder.appendingPathComponent("rotation-source.png"))
                try writePNG(rotatedFrame, to: folder.appendingPathComponent("rotation-output.png"))
                for point in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.65), (0.8, 0.65)] {
                    let a = rgba(sourceFrame, x: point.0, y: point.1), b = rgba(rotatedFrame, x: point.0, y: point.1)
                    try require(zip(a, b).allSatisfy { abs($0 - $1) < 0.15 }, "Video rotated/mirrored differently on export: \(point) \(a) vs \(b)")
                }
            }
            let (overlapFrame, _) = try await generator.image(at: CMTime(seconds: 1.7, preferredTimescale: 600))
            try writePNG(overlapFrame, to: folder.appendingPathComponent("overlap-\(format.id).png"))
            print("PASS: \(format.rawValue), duration/audio/progress/long Chinese/overlap; prepare=\(String(format: "%.3f", probe.quarterTime ?? -1))s")
        }
        try await MediaEngine.export(settings: ExportSettings(clips: [video, short, delayed], captions: [], format: .portrait,
            musicURL: nil, musicVolume: 0, outputURL: folder.appendingPathComponent("silent-portrait.mp4"))) { _ in }
        try await verifyMovie(folder.appendingPathComponent("silent-portrait.mp4"), size: VideoFormat.portrait.size,
                              duration: video.duration + short.duration + delayed.duration, audio: false)
        print("PASS: short and delayed source export, original audio excluded")
        try await verifyFailures(image: jpeg, folder: folder)

        var repeats: [MediaClip] = []
        for _ in 0..<8 { var copy = jpeg; copy.id = UUID(); copy.duration = 2; repeats.append(copy) }
        let probe = ProgressProbe()
        try await MediaEngine.export(settings: ExportSettings(clips: repeats, captions: [], format: .landscape,
            musicURL: nil, musicVolume: 0, outputURL: folder.appendingPathComponent("repeated-photos.mp4"))) { probe.record($0) }
        try probe.verify()
        try await verifyMovie(folder.appendingPathComponent("repeated-photos.mp4"), size: VideoFormat.landscape.size, duration: 16, audio: false)
        print("PASS: 8 repeats, one still source reused; prepare=\(String(format: "%.3f", probe.quarterTime ?? -1))s, total=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - probe.started))s")
        try await verifyResponsiveExport(image: jpeg, folder: folder)
        try await verifyPhoneFormats(folder: folder)
        print("ALL MEDIA CHECKS PASSED: \(folder.path)")
    }

    @MainActor private static func verifyFailures(image: MediaClip, folder: URL) async throws {
        let protected = folder.appendingPathComponent("preserve-existing.mp4")
        let sentinel = Data("existing file stays intact".utf8)
        try sentinel.write(to: protected)
        var longImage = image; longImage.duration = 30
        let cancelled = Task {
            try await MediaEngine.export(settings: ExportSettings(clips: [longImage], captions: [], format: .landscape,
                musicURL: nil, musicVolume: 0, outputURL: protected)) { _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000); MediaEngine.cancelExport()
        do { try await cancelled.value; throw StudioError.message("Cancelled export unexpectedly completed") }
        catch is CancellationError { }
        try require(try Data(contentsOf: protected) == sentinel, "Cancellation replaced existing output")
        let corrupt = folder.appendingPathComponent("corrupt.png")
        try Data("This is not an image or a video".utf8).write(to: corrupt)
        do { _ = try await MediaEngine.inspect(url: corrupt); throw StudioError.message("Corrupt input imported") }
        catch let error as StudioError {
            if error.localizedDescription == "Corrupt input imported" { throw error }
        } catch { }
        for path in ["corrupt.png", "missing-source.png", "broken.mp4"] {
            var bad = image; bad.url = folder.appendingPathComponent(path)
            if path == "broken.mp4" { bad.kind = .video; try Data([0, 0, 0, 8, 102, 116, 121, 112]).write(to: bad.url) }
            var failed = false
            do { try await MediaEngine.export(settings: ExportSettings(clips: [bad], captions: [], format: .landscape,
                musicURL: nil, musicVolume: 0, outputURL: protected)) { _ in } }
            catch { failed = true }
            try require(failed, "Bad source unexpectedly exported: \(path)")
            try require(try Data(contentsOf: protected) == sentinel, "Failed export replaced existing output")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".YingShu-") }
        try require(leftovers.isEmpty, "Staged output leaked after error/cancel")
        print("PASS: cancel/missing/corrupt/truncated inputs preserve target; no staged files leaked")
    }

    @MainActor private static func verifyResponsiveExport(image: MediaClip, folder: URL) async throws {
        var clips: [MediaClip] = [], captions: [Caption] = []
        for index in 0..<20 {
            var clip = image; clip.id = UUID(); clip.duration = 0.5; clips.append(clip)
            for (j, style) in CaptionStyle.allCases.enumerated() {
                captions.append(Caption(clipID: clip.id, start: Double(j) * 0.1, duration: 0.2,
                    text: "第\(index)段第\(j)句：" + String(repeating: "在海边看着光落下来，留下自己当时的感受。", count: 4), style: style))
            }
        }
        var maxGap = 0.0
        let heartbeat = Task { @MainActor in
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; maxGap = max(maxGap, now - last); last = now
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { heartbeat.cancel() }
        try await Task.sleep(nanoseconds: 30_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        try await MediaEngine.export(settings: ExportSettings(clips: clips, captions: captions, format: .portrait,
            musicURL: nil, musicVolume: 0, outputURL: folder.appendingPathComponent("heartbeat.mp4"))) { _ in }
        heartbeat.cancel(); await heartbeat.value
        try require(maxGap < 0.75, "UI actor stalled for \(maxGap)s during export")
        print("PASS: 60-caption export total=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))s; max UI actor gap=\(String(format: "%.3f", maxGap))s")
    }

    @MainActor private static func verifyPhoneFormats(folder: URL) async throws {
        var clips: [MediaClip] = []
        for name in ["oriented.png", "oriented.heif", "synthetic-bayer.dng"] {
            let url = folder.appendingPathComponent(name)
            var clip = try await MediaEngine.inspect(url: url)
            try require(clip.kind == .image, "Phone photo classification failed: \(name)")
            guard let preview = MediaEngine.previewImage(url: url) else { throw StudioError.message("Photo preview unavailable: \(name)") }
            if name.hasSuffix("heif") { try require(preview.size.height > preview.size.width, "HEIF EXIF primary preview wrong") }
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let type = CGImageSourceGetType(source) as String?
            if name.hasSuffix("dng") { try require(type == "com.adobe.raw-image", "Fixture is not parsed as real RAW DNG: \(type ?? "nil")") }
            clip.duration = 0.4; clips.append(clip)
            print("PASS: \(name) actual decoder=\(type ?? "unknown"), preview=\(preview.size)")
        }
        for name in ["h264.mov", "hevc-sdr.mov", "hevc-sdr.mp4", "hdr10.mov", "highfps120.mov", "highfps240.mp4"] {
            var clip = try await MediaEngine.inspect(url: folder.appendingPathComponent(name))
            try require(clip.kind == .video, "Phone video classification failed: \(name)")
            let track = try await AVURLAsset(url: clip.url).loadTracks(withMediaType: .video).first!
            let descriptions = try await track.load(.formatDescriptions)
            let codec = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let frameRate = try await track.load(.nominalFrameRate)
            if name.hasPrefix("hevc") || name.hasPrefix("hdr") { try require(codec == kCMVideoCodecType_HEVC, "HEVC fixture is not actually HEVC") }
            if name.hasPrefix("highfps120") { try require(frameRate >= 119, "Fixture is not actually 120 fps") }
            if name.hasPrefix("highfps240") { try require(frameRate >= 239, "Fixture is not actually 240 fps") }
            if name.hasPrefix("hdr"), let description = descriptions.first {
                let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                try require(transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ, "HDR fixture lacks actual PQ metadata")
            }
            let thumbnail = await MediaEngine.thumbnail(for: clip)
            try require(thumbnail != nil, "Video decoder did not produce a thumbnail: \(name)")
            clip.duration = 0.6; clips.append(clip)
        }
        let output = folder.appendingPathComponent("phone-formats.mp4")
        try await MediaEngine.export(settings: ExportSettings(clips: clips, captions: [], format: .landscape,
            musicURL: nil, musicVolume: 0, outputURL: output)) { _ in }
        try await verifyMovie(output, size: VideoFormat.landscape.size, duration: clips.totalDuration, audio: false)
        let outputTrack = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first!
        let outputDescriptions = try await outputTrack.load(.formatDescriptions)
        let transfer = outputDescriptions.first.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String }
        try require(transfer == AVVideoTransferFunction_ITU_R_709_2, "HDR input was not exported with SDR BT.709 transfer")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output)); generator.appliesPreferredTrackTransform = true
        for clip in clips {
            let time = clips.startTime(of: clip.id) + min(0.2, clip.duration / 2)
            _ = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        }
        for (name, phrase) in [("IMG_0001.AAE", "侧车"), (".IMG_0001.HEIC.icloud", "占位"), ("test.photoslibrary", "图库")] {
            let url = folder.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: url)
            try require(MediaEngine.importNotice(for: url)?.contains(phrase) == true, "Import notice missing for \(name)")
            var rejected = false
            do { _ = try await MediaEngine.inspect(url: url) } catch { rejected = true }
            try require(rejected, "Nonmedia input was accepted")
        }
        print("PASS: PNG/HEIF/Bayer DNG; H.264 MOV; HEVC MOV/MP4; 10-bit PQ HDR→SDR; 120/240 fps; all exported segments decode")
        print("NOTE: generated DNG is not an iPhone ProRAW; HDR10 is not a Dolby Vision device recording; real Live Photo pairing/iCloud eviction not exercised")
    }

    private static func verifyMovie(_ url: URL, size: CGSize, duration: Double, audio: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let actualDuration = try await asset.load(.duration).seconds
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.message("Export has no video") }
        let dimensions = try await video.load(.naturalSize)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try require(dimensions == size, "Wrong render size: \(dimensions)")
        try require(abs(actualDuration - duration) < 0.1, "Wrong exported duration: \(actualDuration) vs \(duration)")
        try require(audioTracks.isEmpty != audio, "Unexpected audio tracks")
    }

    private static func createPhotos(in folder: URL) throws {
        let width = 640, height = 360
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let color: [UInt8] = y < height / 2 ? (x < width / 2 ? [255, 0, 0] : [0, 255, 0]) : (x < width / 2 ? [0, 0, 255] : [255, 255, 0])
            let i = (y * width + x) * 4
            pixels[i] = color[0]; pixels[i + 1] = color[1]; pixels[i + 2] = color[2]
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        for (name, type) in [("oriented.jpg", UTType.jpeg.identifier), ("oriented.heic", UTType.heic.identifier),
                             ("oriented.heif", UTType.heic.identifier), ("oriented.png", UTType.png.identifier)] {
            guard let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, type as CFString, 1, nil) else {
                throw StudioError.message("Cannot create orientation fixture")
            }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
            try require(CGImageDestinationFinalize(destination), "Cannot save orientation fixture")
        }
    }

    private static func rgba(_ image: CGImage, x: Double, y: Double) -> [Double] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            let sampleX = CGFloat(Int(x * Double(image.width - 1)))
            let sampleY = CGFloat(Int((1 - y) * Double(image.height - 1)))
            let rect = CGRect(x: -sampleX, y: -sampleY, width: CGFloat(image.width), height: CGFloat(image.height))
            context.draw(image, in: rect)
        }
        return bytes.prefix(3).map { Double($0) / 255 }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(target, image, nil)
        try require(CGImageDestinationFinalize(target), "Could not save verification frame")
    }
}
