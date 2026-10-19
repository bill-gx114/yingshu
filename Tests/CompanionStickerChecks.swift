import AppKit
import AVFoundation
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import Vision

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw StudioError.message(message) }
}

@main struct CompanionStickerChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dist = root.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yingshu-companion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var clip = try await MediaEngine.inspect(url: root.appendingPathComponent("Resources/demo-coast.png"))
        clip.duration = 4; clip.name = "原创海边示例"
        let thought = Caption(clipID: clip.id, start: 0.3, duration: 3.5, text: "那天的海风很轻，\n我也慢慢走。", style: .companion)

        var sprites: [CGImage] = []
        for index in 0..<CompanionStickerRenderer.poseCount {
            let url = root.appendingPathComponent(String(format: "Resources/companion-%02d.png", index))
            let image = try load(url)
            try check(image.width == 512 && image.height == 640 && image.alphaInfo != .none, "Missing transparent 3D pose")
            sprites.append(image)
        }
        try check(difference(sprites[0], sprites[12]) > 0.05, "Front and side are not distinct rendered poses")
        try check(difference(sprites[0], sprites[24]) < 0.002, "One gentle gesture must settle to front")
        try check(CompanionStickerRenderer.poseIndex(elapsed: nil) == 0 && CompanionStickerRenderer.poseIndex(elapsed: 8) == 24,
                  "Static poster or final pose is unstable")
        print("PASS 25 transparent original clay poses, real front/side silhouette, one settled gesture")

        for format in VideoFormat.allCases {
            let canvas = format.size
            let styles = [thought,
                Caption(clipID: clip.id, start: 0.3, duration: 3, text: "认真看了一次海。", style: .subtitle),
                Caption(clipID: clip.id, start: 0.3, duration: 3, text: "给自己一点时间。", style: .sticker),
                Caption(clipID: clip.id, start: 0.3, duration: 3, text: "把风的声音记在心里。", style: .note)]
            let layers = MediaEngine.renderedCaptions(styles, canvas: canvas, localTime: 0.9)
            try check(Set(layers.compactMap { $0.value(forKey: "captionID") as? String }) == Set(styles.map { $0.id.uuidString }), "Caption identity was lost")
            try check(layers.allSatisfy { $0.value(forKey: "clipID") as? String == clip.id.uuidString }, "Clip identity was lost")
            for layer in layers {
                try check(CGRect(origin: .zero, size: canvas).insetBy(dx: -1, dy: -1).contains(layer.frame), "Caption overflows \(format.rawValue)")
            }
            for i in layers.indices { for j in layers.indices where j > i {
                try check(!layers[i].frame.intersects(layers[j].frame), "Companion covers another caption")
            } }
            let long = (0..<4).map { Caption(clipID: clip.id, start: Double($0) * 0.01, duration: 3,
                text: String(repeating: "慢慢走，沿途的风也值得被记住。", count: 15), style: .companion) }
            for layer in MediaEngine.renderedCaptions(long, canvas: canvas, localTime: 0.8) {
                try check(CGRect(origin: .zero, size: canvas).insetBy(dx: -1, dy: -1).contains(layer.frame), "Compact companion escaped canvas")
                try check(layer.name == "caption-compact", "Long companion group needs shared compact scaling")
            }
            let urls = try await CaptionImageExporter.export(clips: [clip], captions: [thought], format: format, to: scratch) { _ in }
            try check(urls.count == 1, "Companion PNG batch has wrong count")
            let image = try load(urls[0]), recognized = try recognize(image)
            try check(recognized.contains("那天的海风很轻") && recognized.contains("我也慢慢走"), "Companion Chinese text is unreadable: \(recognized)")
            if format == .landscape {
                let preview = dist.appendingPathComponent("小人气泡效果预览.png")
                try? FileManager.default.removeItem(at: preview); try FileManager.default.copyItem(at: urls[0], to: preview)
            }
            print("PASS \(format.rawValue) companion PNG OCR, four-style collision avoidance, compact bounds and IDs")
        }
        // This short, right-hand sticker splits the companion into three groups
        // while its turn is in progress. It must not restart the character gesture.
        let splitter = Caption(clipID: clip.id, start: 0.82, duration: 0.22, text: "海边随记", style: .sticker)
        let video = dist.appendingPathComponent("小人气泡效果预览.mp4")
        try await MediaEngine.export(settings: ExportSettings(clips: [clip], captions: [thought, splitter], format: .landscape,
                                                               musicURL: nil, musicVolume: 0, outputURL: video)) { _ in }
        let asset = AVURLAsset(url: video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try check(audioTracks.isEmpty, "Silent companion export unexpectedly has audio")
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var frames: [CGImage] = []
        for time in [0.4, 0.9, 1.8, 2.6] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            frames.append(frame)
        }
        let layers = MediaEngine.renderedCaptions([thought], canvas: VideoFormat.landscape.size, localTime: 0.9)
        let companion = layers[0], character = companion.sublayers!.first { $0.name == "companion-character" }!
        let world = character.frame.offsetBy(dx: companion.frame.minX, dy: companion.frame.minY)
        let crop = CGRect(x: world.minX, y: 1080 - world.maxY, width: world.width, height: world.height).integral
        let crops = frames.map { $0.cropping(to: crop)! }
        let turn = difference(crops[0], crops[1]), settled = difference(crops[2], crops[3])
        try check(turn > 0.025, "Exported MP4 does not visibly change real character pose: \(turn)")
        try check(settled < 0.008, "Character keeps moving after its one gentle turn: \(settled)")
        // Check the split-group frame matches the local-time preview pose rather
        // than restarting at the front pose when the other sticker appears.
        let expected = try expectedFrame(sourceURL: clip.url, captions: [thought, splitter], canvas: VideoFormat.landscape.size, time: 0.9)
        let expectedCrop = expected.cropping(to: crop)!
        try check(difference(crops[1], expectedCrop) < 0.04, "Overlap split restarted or desynchronized the companion turn")
        for (index, frame) in frames.enumerated() { try write(frame, to: scratch.appendingPathComponent("frame-\(index).png")) }
        print("PASS actual silent MP4 motion; front/side difference=\(turn), settled difference=\(settled); group split agrees with preview")
        print("PREVIEW \(video.path)")
        print("PREVIEW \(dist.appendingPathComponent("小人气泡效果预览.png").path)")
    }

    private static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StudioError.message("Cannot decode \(url.lastPathComponent)") }
        return image
    }
    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().replacingOccurrences(of: " ", with: "")
    }
    private static func rgba(_ image: CGImage, size: CGSize) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        bytes.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                    bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
        return bytes
    }
    private static func difference(_ left: CGImage, _ right: CGImage) -> Double {
        let size = CGSize(width: 128, height: 160), a = rgba(left, size: size), b = rgba(right, size: size)
        var difference = 0.0
        for index in a.indices where index % 4 != 3 { difference += abs(Double(a[index]) - Double(b[index])) / 255 }
        return difference / Double(128*160*3)
    }
    @MainActor private static func expectedFrame(sourceURL: URL, captions: [Caption], canvas: CGSize, time: Double) throws -> CGImage {
        let source = try load(sourceURL)
        let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(origin: .zero, size: canvas))
        let scale = min(canvas.width / CGFloat(source.width), canvas.height / CGFloat(source.height))
        context.draw(source, in: CGRect(x: (canvas.width - CGFloat(source.width) * scale) / 2,
                                       y: (canvas.height - CGFloat(source.height) * scale) / 2,
                                       width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale))
        let root = CALayer(); root.frame = CGRect(origin: .zero, size: canvas)
        for layer in MediaEngine.renderedCaptions(captions, canvas: canvas, localTime: time) { root.addSublayer(layer) }
        root.layoutIfNeeded(); root.render(in: context)
        return context.makeImage()!
    }
    private static func write(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "Cannot save preview")
    }
}
