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
        let dist = root.appendingPathComponent("Tests/output/companion-checks", isDirectory: true)
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

        let oldProfile = try JSONDecoder().decode(CompanionProfile.self, from: Data(#"{"name":"旧旅伴","skinTone":"cream","hairStyle":"bucketHat","hairColor":"espresso","faceShape":"round","outfitColor":"coral","glassesStyle":"none"}"#.utf8))
        try check(oldProfile.portraitTraits == nil && oldProfile.isClassicAppearance,
                  "A saved pre-photo companion must retain its exact classic rendering")
        var explicitStandard = CompanionProfile.classic
        explicitStandard.portraitTraits = .standard
        try check(explicitStandard.visualKey == CompanionProfile.classic.visualKey && explicitStandard.normalized().portraitTraits == nil &&
                  CompanionStickerRenderer.previewImage(for: explicitStandard) === CompanionStickerRenderer.previewImage(for: .classic),
                  "Default facial traits must not invalidate the classic PNG path")
        let partialTraits = try JSONDecoder().decode(CompanionProfile.self,
            from: Data(#"{"portraitTraits":{"eyeShape":"future-shape","eyeSpacing":"wide","smile":7}}"#.utf8))
        try check(partialTraits.portraitTraits == CompanionPortraitTraits(eyeSpacing: .wide),
                  "Unknown or malformed photo traits must fall back independently")
        let invalidTraits = try JSONDecoder().decode(CompanionProfile.self, from: Data(#"{"portraitTraits":"invalid"}"#.utf8))
        try check(invalidTraits.portraitTraits == nil && invalidTraits.isClassicAppearance,
                  "Invalid facial-traits payload must remain compatible with old projects")
        print("PASS old companion JSON and classic PNG identity, normalized default traits and field-level fallback")

        let personal = CompanionProfile(name: "小栗", skinTone: .honey, hairStyle: .curls,
            hairColor: .chestnut, faceShape: .oval, outfitColor: .sage, glassesStyle: .round,
            portraitTraits: CompanionPortraitTraits(eyeShape: .bright, eyeSpacing: .wide, smile: .sunny))
        let secondPersonal = CompanionProfile(name: "阿蓝", skinTone: .deep, hairStyle: .short,
            hairColor: .silver, faceShape: .softSquare, outfitColor: .ocean, glassesStyle: .square)
        let thirdPersonal = CompanionProfile(name: "小桃", skinTone: .peach, hairStyle: .bun,
            hairColor: .espresso, faceShape: .round, outfitColor: .lavender, glassesStyle: .none)
        let profiles = [personal, secondPersonal, thirdPersonal]
        var personalFronts: [CGImage] = []
        for profile in profiles {
            try await CompanionStickerRenderer.prepare(profile)
            guard let front = CompanionStickerRenderer.previewImage(for: profile) else { throw StudioError.message("Personal companion has no preview") }
            try check(front.width == 512 && front.height == 640 && front.alphaInfo != .none, "Personal companion lost its transparent clay canvas")
            try check(difference(front, sprites[0]) > 0.025, "Personal look is indistinguishable from the classic look")
            var poses: [CGImage] = []
            for index in 0..<CompanionStickerRenderer.poseCount {
                let elapsed = (Double(index) + 0.001) / Double(CompanionStickerRenderer.poseCount - 1) * CompanionStickerRenderer.turnDuration
                let layer = CompanionStickerRenderer.layer(for: thought, canvas: VideoFormat.landscape.size,
                    localTime: thought.start + elapsed, companionProfile: profile)
                guard let character = layer.sublayers?.first(where: { $0.name == "companion-character" }),
                      let pose = character.contents as! CGImage? else { throw StudioError.message("Personal pose missing") }
                poses.append(pose)
            }
            try check(poses.count == 25 && difference(poses[0], poses[12]) > 0.01 && difference(poses[0], poses[24]) < 0.002,
                      "Personal companion must keep its own stable 25-pose turn")
            personalFronts.append(front)
            try write(front, to: dist.appendingPathComponent("personal-\(profile.hairStyle.rawValue).png"))
        }
        try check(difference(personalFronts[0], personalFronts[1]) > 0.035 && difference(personalFronts[0], personalFronts[2]) > 0.035,
                  "Different personal choices must remain visibly distinct")
        let traitBase = CompanionProfile(skinTone: .peach, hairStyle: .short, hairColor: .chestnut, outfitColor: .sage)
        let traitLooks: [(String, CompanionPortraitTraits?)] = [
            ("柔和", nil),
            ("明亮", CompanionPortraitTraits(eyeShape: .bright, eyeSpacing: .wide, smile: .sunny)),
            ("爱笑", CompanionPortraitTraits(eyeShape: .smiling, eyeSpacing: .close, smile: .sunny)),
            ("安静", CompanionPortraitTraits(eyeSpacing: .close, smile: .subtle))]
        var traitImages: [CGImage] = []
        for (title, traits) in traitLooks {
            var profile = traitBase; profile.portraitTraits = traits
            try await CompanionStickerRenderer.prepare(profile)
            let decoded = try JSONDecoder().decode(CompanionProfile.self, from: JSONEncoder().encode(profile))
            try check(decoded == profile && decoded.visualKey == profile.visualKey, "Facial traits failed to survive project persistence")
            guard let front = CompanionStickerRenderer.previewImage(for: profile) else { throw StudioError.message("Photo traits have no clay preview") }
            traitImages.append(front)
            try write(front, to: dist.appendingPathComponent("portrait-traits-\(title).png"))
            let side = CompanionStickerRenderer.layer(for: thought, canvas: VideoFormat.landscape.size,
                localTime: thought.start + 0.601, companionProfile: profile)
            let settled = CompanionStickerRenderer.layer(for: thought, canvas: VideoFormat.landscape.size,
                localTime: thought.start + CompanionStickerRenderer.turnDuration, companionProfile: profile)
            let sideImage = side.sublayers!.first { $0.name == "companion-character" }!.contents as! CGImage
            let settledImage = settled.sublayers!.first { $0.name == "companion-character" }!.contents as! CGImage
            try check(difference(front, sideImage) > 0.01 && difference(front, settledImage) < 0.002,
                      "Photo-derived expression must preserve all animated poses and settle consistently")
        }
        for index in 1..<traitImages.count {
            let region = CGRect(x: 125, y: 100, width: 262, height: 230)
            try check(difference(traitImages[0].cropping(to: region)!, traitImages[index].cropping(to: region)!) > 0.002,
                      "Photo facial traits must change visible facial features, not only stored metadata")
        }
        try write(traitContactSheet(traitImages, titles: traitLooks.map(\.0)), to: dist.appendingPathComponent("照片神韵对照.png"))
        print("PASS four distinct gentle facial expressions, persistence and 25-pose motion with bounded clay proportions")
        var renamed = personal; renamed.name = "只改昵称"
        try check(renamed.visualKey == personal.visualKey && CompanionStickerRenderer.previewImage(for: renamed) === CompanionStickerRenderer.previewImage(for: personal),
                  "Renaming must preserve the same visual rendering")
        print("PASS three distinct personal clay looks, 25 stable poses each and display-only nickname identity")
        let validatedLayer = CompanionStickerRenderer.layer(for: thought, canvas: VideoFormat.landscape.size,
            localTime: nil, companionProfile: personal)
        try CompanionStickerRenderer.validateExportLayer(validatedLayer)
        CompanionStickerRenderer.animate(validatedLayer, captionStart: thought.start, totalDuration: clip.duration, companionProfile: personal)
        try CompanionStickerRenderer.validateExportLayer(validatedLayer, animated: true)
        guard let validatedCharacter = validatedLayer.sublayers?.first(where: { $0.name == "companion-character" }) else {
            throw StudioError.message("Validation fixture has no companion")
        }
        validatedCharacter.removeAllAnimations()
        var rejectedIncomplete = false
        do { try CompanionStickerRenderer.validateExportLayer(validatedLayer, animated: true) } catch { rejectedIncomplete = true }
        try check(rejectedIncomplete, "An animation lost before export must be rejected instead of silently saving a static companion")
        validatedCharacter.contents = nil
        rejectedIncomplete = false
        do { try CompanionStickerRenderer.validateExportLayer(validatedLayer) } catch { rejectedIncomplete = true }
        try check(rejectedIncomplete, "Missing companion pixels must fail export instead of silently saving a speech bubble alone")
        print("PASS complete export-layer acceptance and explicit rejection of missing pixels or animation")

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
                let explicitClassic = try await CaptionImageExporter.export(clips: [clip], captions: [thought], format: format,
                    to: scratch, companionProfile: .classic, progress: { _ in })
                try check(difference(image, try load(explicitClassic[0])) < 0.000001,
                          "Omitting a profile must preserve the exact classic PNG output")
            }
            print("PASS \(format.rawValue) companion PNG OCR, four-style collision avoidance, compact bounds and IDs")
        }
        // This short, right-hand sticker splits the companion into three groups
        // while its turn is in progress. It must not restart the character gesture.
        let splitter = Caption(clipID: clip.id, start: 0.82, duration: 0.22, text: "海边随记", style: .sticker)
        let video = dist.appendingPathComponent("小人气泡效果预览.mp4")
        let capturedSettings = ExportSettings(clips: [clip], captions: [thought, splitter], format: .landscape,
            musicURL: nil, musicVolume: 0, outputURL: video, companionProfile: personal)
        // Preparing a different look after capturing the export must not redirect
        // the export through whichever profile most recently reached the cache.
        try await CompanionStickerRenderer.prepare(secondPersonal)
        try await MediaEngine.export(settings: capturedSettings) { _ in }
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
        let layers = MediaEngine.renderedCaptions([thought], canvas: VideoFormat.landscape.size, localTime: 0.9, companionProfile: personal)
        let companion = layers[0], character = companion.sublayers!.first { $0.name == "companion-character" }!
        let world = character.frame.offsetBy(dx: companion.frame.minX, dy: companion.frame.minY)
        let crop = CGRect(x: world.minX, y: 1080 - world.maxY, width: world.width, height: world.height).integral
        let crops = frames.map { $0.cropping(to: crop)! }
        let turn = difference(crops[0], crops[1]), settled = difference(crops[2], crops[3])
        try check(turn > 0.025, "Exported MP4 does not visibly change real character pose: \(turn)")
        try check(settled < 0.008, "Character keeps moving after its one gentle turn: \(settled)")
        // Check the split-group frame matches the local-time preview pose rather
        // than restarting at the front pose when the other sticker appears.
        let expected = try expectedFrame(sourceURL: clip.url, captions: [thought, splitter], canvas: VideoFormat.landscape.size, time: 0.9, profile: personal)
        let expectedCrop = expected.cropping(to: crop)!
        try check(difference(crops[1], expectedCrop) < 0.04, "Overlap split restarted or desynchronized the companion turn")
        let wrongLook = try expectedFrame(sourceURL: clip.url, captions: [thought, splitter], canvas: VideoFormat.landscape.size, time: 0.9, profile: secondPersonal)
        try check(difference(crops[1], expectedCrop) + 0.015 < difference(crops[1], wrongLook.cropping(to: crop)!),
                  "MP4 export did not retain the profile captured in ExportSettings")
        let personalPNG = try await CaptionImageExporter.export(clips: [clip], captions: [thought], format: .landscape,
            to: scratch, companionProfile: personal, progress: { _ in })
        let png = try load(personalPNG[0])
        let pngExpected = try expectedFrame(sourceURL: clip.url, captions: [thought], canvas: VideoFormat.landscape.size,
            time: thought.start + thought.duration / 2, profile: personal)
        try check(difference(png.cropping(to: crop)!, pngExpected.cropping(to: crop)!) < 0.005,
                  "Caption PNG must use the same project profile as preview and MP4")
        try write(png, to: dist.appendingPathComponent("个人小旅伴图片预览.png"))
        for (index, frame) in frames.enumerated() { try write(frame, to: scratch.appendingPathComponent("frame-\(index).png")) }
        print("PASS personal PNG/preview/MP4 agreement, captured profile isolation, actual silent motion; front/side difference=\(turn), settled difference=\(settled); group split agrees with preview")
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
    @MainActor private static func expectedFrame(sourceURL: URL, captions: [Caption], canvas: CGSize, time: Double, profile: CompanionProfile = .classic) throws -> CGImage {
        let source = try load(sourceURL)
        let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(origin: .zero, size: canvas))
        let scale = min(canvas.width / CGFloat(source.width), canvas.height / CGFloat(source.height))
        context.draw(source, in: CGRect(x: (canvas.width - CGFloat(source.width) * scale) / 2,
                                       y: (canvas.height - CGFloat(source.height) * scale) / 2,
                                       width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale))
        let root = CALayer(); root.frame = CGRect(origin: .zero, size: canvas)
        for layer in MediaEngine.renderedCaptions(captions, canvas: canvas, localTime: time, companionProfile: profile) { root.addSublayer(layer) }
        root.layoutIfNeeded(); root.render(in: context)
        return context.makeImage()!
    }
    private static func write(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "Cannot save preview")
    }
    @MainActor private static func traitContactSheet(_ images: [CGImage], titles: [String]) -> CGImage {
        let size = CGSize(width: 1200, height: 510), image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: 0.967, green: 0.958, blue: 0.936, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, source) in images.enumerated() {
            let x = CGFloat(index) * 300
            let rect = CGRect(x: x + 12, y: 50, width: 276, height: 390)
            NSColor(srgbRed: 0.89, green: 0.92, blue: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20).fill()
            NSImage(cgImage: source, size: CGSize(width: 512, height: 640)).draw(in: rect.insetBy(dx: 4, dy: 10))
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (titles[index] as NSString).draw(in: CGRect(x: x, y: 14, width: 300, height: 28), withAttributes: [
                .font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: NSColor.darkGray, .paragraphStyle: paragraph])
        }
        ("照片只留下神韵 · 同一造型的四种黏土表情" as NSString).draw(at: CGPoint(x: 25, y: 465), withAttributes: [
            .font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.darkGray])
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }
}
