import AppKit
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw StudioError.message(message) }
}

@main struct LivePhotoChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); Foundation.exit(1) }
    }

    @MainActor private static func run() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/fixtures/live-photo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "14503168-13BD-491A-AF19-3757DA316567"
        let heicID = "A016D861-F8C2-4FBC-9034-08DBF5B0629F"
        let still = folder.appendingPathComponent("seaside-still.jpg")
        let movie = folder.appendingPathComponent("different-name-motion.mov")
        let heic = folder.appendingPathComponent("iphone-style-still.heic")
        let heicMovie = folder.appendingPathComponent("iphone-style-motion.mov")
        let date = "2026:10:17 09:45:12"
        let photoExif: [String: Any] = [kCGImagePropertyExifDateTimeOriginal as String: date,
            kCGImagePropertyExifOffsetTimeOriginal as String: "+09:00", kCGImagePropertyExifSubsecTimeOriginal as String: "125"]
        try makePhoto(url: still, id: id, exif: photoExif)
        try makePhoto(url: heic, id: heicID, exif: photoExif)
        try await makeMovie(url: movie, id: id)
        try await makeMovie(url: heicMovie, id: heicID)
        print("FIXTURES: \(still.path) + \(movie.path)")
        print("FIXTURES: \(heic.path) + \(heicMovie.path)")
        let accepted = await LivePhotoImporter.systemValidates(stillURL: still, movieURL: movie)
        let heicAccepted = await LivePhotoImporter.systemValidates(stillURL: heic, movieURL: heicMovie)
        try check(accepted && heicAccepted, "PHLivePhoto rejected generated JPEG/HEIC resource pair")
        print("PASS: PHLivePhoto validates generated JPEG and HEIC + MOV resources")

        let ordinary = folder.appendingPathComponent("ordinary.png")
        try makePhoto(url: ordinary, id: nil)
        let prepared = await LivePhotoImporter.prepare(urls: [movie, ordinary, still])
        try check(prepared.count == 2 && prepared[0].url == ordinary, "Pairing lost the still's original input position")
        try check(prepared[1].url == movie && prepared[1].stillURL == still && prepared[1].livePhotoAssetID == id, "Unique true identifier did not pair")
        let heicPrepared = await LivePhotoImporter.prepare(urls: [heic, heicMovie])
        try check(heicPrepared.count == 1 && heicPrepared[0].stillURL == heic, "HEIC pair did not merge")
        let standalone = await LivePhotoImporter.prepare(urls: [still])
        try check(standalone.count == 1 && standalone[0].stillURL == nil && standalone[0].livePhotoAssetID == id, "Missing motion should preserve identified still")

        let duplicateStill = folder.appendingPathComponent("duplicate-still.jpg")
        try replaceCopy(from: still, to: duplicateStill)
        let duplicateMovie = folder.appendingPathComponent("duplicate-motion.mov")
        try replaceCopy(from: movie, to: duplicateMovie)
        for urls in [[still, duplicateStill, movie], [still, movie, duplicateMovie], [still, still, movie]] {
            let candidates = await LivePhotoImporter.prepare(urls: urls)
            try check(candidates.count == urls.count && candidates.allSatisfy { $0.stillURL == nil }, "Ambiguous identity consumed an original")
        }
        let sameNamePhoto = folder.appendingPathComponent("same-name.jpg")
        let sameNameMovie = folder.appendingPathComponent("same-name.mov")
        try makePhoto(url: sameNamePhoto, id: nil)
        try await makeMovie(url: sameNameMovie, id: nil)
        let sameName = await LivePhotoImporter.prepare(urls: [sameNamePhoto, sameNameMovie])
        try check(sameName.count == 2 && sameName.allSatisfy { $0.stillURL == nil }, "Filename was incorrectly used as pairing evidence")
        let mismatched = await LivePhotoImporter.prepare(urls: [still, heicMovie])
        try check(mismatched.count == 2, "Mismatched content identifiers were merged")
        let broken = folder.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: broken)
        let brokenResult = await LivePhotoImporter.prepare(urls: [still, broken])
        try check(brokenResult.count == 2 && brokenResult[0].livePhotoAssetID == id, "Unreadable motion consumed still")
        print("PASS: unique matching IDs, still-position ordering, unmatched still notice, mismatches, same-name negatives, duplicate ambiguity, broken movie")

        var clip = try await MediaEngine.inspect(url: movie)
        clip.livePhotoStillURL = still; clip.livePhotoAssetID = id
        try check(clip.kind == .video && clip.duration > 1, "Paired media is not a moving video clip")
        guard let poster = await MediaEngine.thumbnail(for: clip),
              let posterCG = poster.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw StudioError.message("Poster missing") }
        let posterPixel = pixel(posterCG)
        try check(posterPixel[2] > 0.7 && posterPixel[0] < 0.3, "Timeline poster did not use paired still")
        let output = folder.appendingPathComponent("live-photo-export.mp4")
        try await MediaEngine.export(settings: ExportSettings(clips: [clip], captions: [], format: .landscape,
            musicURL: nil, musicVolume: 0, outputURL: output)) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let (later, _) = try await generator.image(at: CMTime(seconds: 1.7, preferredTimescale: 600))
        let firstColor = pixel(first), laterColor = pixel(later)
        try check(zip(firstColor, laterColor).map { abs($0 - $1) }.reduce(0, +) > 0.5, "Export froze the still photo instead of playing motion")
        print("PASS: paired clip kind.video, paired still poster, exported MP4 contains changing frames")

        let imageInfo = try await MediaEngine.inspect(url: still)
        let iso = ISO8601DateFormatter()
        let expected = iso.date(from: "2026-10-17T00:45:12Z")!.addingTimeInterval(0.125)
        try check(abs((imageInfo.capturedAt ?? .distantPast).timeIntervalSince(expected)) < 0.001, "Photo EXIF offset/subseconds were not applied")
        try check(imageInfo.fileCreatedAt != nil, "File creation date was not read")
        try check(abs((clip.capturedAt ?? .distantPast).timeIntervalSince(iso.date(from: "2026-10-16T23:01:02Z")!)) < 0.001, "QuickTime creation date was not read")
        let originalPriority = folder.appendingPathComponent("original-date-priority.jpg")
        try makePhoto(url: originalPriority, id: nil, exif: [
            kCGImagePropertyExifDateTimeOriginal as String: "2026:10:15 08:00:00",
            kCGImagePropertyExifDateTimeDigitized as String: "2026:10:18 09:00:00",
            kCGImagePropertyExifOffsetTimeDigitized as String: "+09:00"
        ])
        let priority = try await MediaEngine.inspect(url: originalPriority)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current; formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let originalDate = formatter.date(from: "2026:10:15 08:00:00")!
        try check(abs((priority.capturedAt ?? .distantPast).timeIntervalSince(originalDate)) < 0.001, "Zoned digitisation date incorrectly overrode original capture time")
        let noDate = try await MediaEngine.inspect(url: ordinary)
        try check(noDate.capturedAt == nil && noDate.fileCreatedAt != nil, "Filesystem date was mislabeled as capture metadata")
        print("PASS: EXIF original/zone/subseconds, original-over-digitised priority, QuickTime creation date, filesystem date kept separate")
        print("ALL LIVE PHOTO CHECKS PASSED; generated resources retained in \(folder.path)")
        print("NOTE: generated standards-compliant resources are tested; real iPhone recordings still require device-sample verification")
    }

    private static func makePhoto(url: URL, id: String?, exif: [String: Any] = [:]) throws {
        let width = 320, height = 180
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = 20; pixels[i + 1] = 35; pixels[i + 2] = 235 }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let type = url.pathExtension == "png" ? UTType.png.identifier : url.pathExtension == "heic" ? UTType.heic.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { throw StudioError.message("Cannot create photo fixture") }
        var properties: [String: Any] = [kCGImagePropertyExifDictionary as String: exif]
        if let id { properties[kCGImagePropertyMakerAppleDictionary as String] = ["17": id] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try check(CGImageDestinationFinalize(destination), "Cannot save photo fixture")
    }

    private static func makeMovie(url: URL, id: String?) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var metadata: [AVMetadataItem] = []
        if let id {
            let item = AVMutableMetadataItem(); item.identifier = .quickTimeMetadataContentIdentifier
            item.value = id as NSString; item.dataType = kCMMetadataBaseDataType_UTF8 as String; metadata.append(item)
        }
        let created = AVMutableMetadataItem(); created.identifier = .quickTimeMetadataCreationDate
        created.value = "2026-10-17T08:01:02+09:00" as NSString; created.dataType = kCMMetadataBaseDataType_UTF8 as String; metadata.append(created)
        writer.metadata = metadata
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        var description: CMMetadataFormatDescription?
        let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description)
        try check(status == noErr, "Cannot create still-image-time metadata description")
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        writer.add(metadataInput)
        try check(writer.startWriting(), "Cannot start movie writer")
        writer.startSession(atSourceTime: .zero)
        let stillTime = AVMutableMetadataItem(); stillTime.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        stillTime.value = NSNumber(value: Int8(0)); stillTime.dataType = kCMMetadataBaseDataType_SInt8 as String
        let group = AVTimedMetadataGroup(items: [stillTime], timeRange: CMTimeRange(start: CMTime(value: 30, timescale: 30), duration: CMTime(value: 1, timescale: 30)))
        try check(metadataAdaptor.append(group), "Cannot write still-image-time track")
        metadataInput.markAsFinished()
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? StudioError.message("Fixture writer stopped") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var buffer: CVPixelBuffer?
            try check(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess,
                "Cannot allocate fixture frame")
            let value = buffer!
            CVPixelBufferLockBaseAddress(value, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(value), width: 320, height: 180, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(value), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(frame) / 60, green: 1 - CGFloat(frame) / 60, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            CVPixelBufferUnlockBaseAddress(value, [])
            try check(adaptor.append(value, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "Cannot write fixture frame")
        }
        writer.endSession(atSourceTime: CMTime(value: 60, timescale: 30)); input.markAsFinished()
        await writer.finishWriting()
        try check(writer.status == .completed, "Fixture writer failed: \(writer.error?.localizedDescription ?? "unknown")")
    }

    private static func replaceCopy(from: URL, to: URL) throws {
        if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
        try FileManager.default.copyItem(at: from, to: to)
    }

    private static func pixel(_ image: CGImage) -> [Double] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2), width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes.prefix(3).map { Double($0) / 255 }
    }
}
