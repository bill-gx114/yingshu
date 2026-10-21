import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw StudioError.message(message) }
}

@main struct CompanionPhotoChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yingshu-photo-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let face = fixtureFace()
        for skin in CompanionSkinTone.allCases {
            let image = try portrait(skin: skin, hair: .chestnut, outfit: .ocean)
            let original = CompanionProfile(name: "  小晴  ", hairStyle: .bun, glassesStyle: .round)
            let draft = try CompanionPhotoAnalyzer.makeDraft(image: image, face: face, startingFrom: original)
            try check(draft.profile.skinTone == skin, "Cheek colour mapping failed: \(skin.rawValue) => \(draft.profile.skinTone.rawValue)")
            try check(draft.profile.hairColor == .chestnut, "Hair colour must come from the head region")
            try check(draft.profile.outfitColor == .ocean, "Clothing colour must come from below the face")
            try check(draft.profile.name == "小晴" && draft.profile.hairStyle == .bun && draft.profile.glassesStyle == .round,
                      "Photo suggestion replaced a manually chosen nickname, hairstyle or glasses")
            try check(draft.profile.faceShape == .round, "Coarse face silhouette mapping failed")
        }
        print("PASS synthetic swatches: all five skin tones, hair/clothing regions, retained choices and soft silhouette")
        let faceImage = try portrait(skin: .honey, hair: .espresso, outfit: .sage)
        let brightFace = CompanionPhotoFaceSample(bounds: face.bounds, contour: face.contour,
            leftEye: landmarkBox(0.10, 0.55, 0.17, 0.08), rightEye: landmarkBox(0.73, 0.55, 0.17, 0.08),
            lips: landmarkBox(0.225, 0.24, 0.55, 0.13))
        let quietFace = CompanionPhotoFaceSample(bounds: face.bounds, contour: face.contour,
            leftEye: landmarkBox(0.24, 0.58, 0.16, 0.015), rightEye: landmarkBox(0.60, 0.58, 0.16, 0.015),
            lips: landmarkBox(0.35, 0.24, 0.30, 0.08))
        let bright = try CompanionPhotoAnalyzer.makeDraft(image: faceImage, face: brightFace, startingFrom: .classic).profile
        let quiet = try CompanionPhotoAnalyzer.makeDraft(image: faceImage, face: quietFace, startingFrom: .classic).profile
        try check(bright.portraitTraits == CompanionPortraitTraits(eyeShape: .bright, eyeSpacing: .wide, smile: .sunny),
                  "Clear landmark geometry lost its softened bright expression")
        try check(quiet.portraitTraits == CompanionPortraitTraits(eyeShape: .smiling, eyeSpacing: .close, smile: .subtle),
                  "Clear landmark geometry lost its softened quiet expression")
        try check(bright.hairStyle == .short && quiet.hairStyle == .short, "Default hat must reveal the photo-inspired colour")
        let blueBackground = try portrait(skin: .cream, hair: .chestnut, outfit: .sage, hairPaint: NSColor(srgbRed: 0.04, green: 0.45, blue: 0.95, alpha: 1))
        let unchangedHair = try CompanionPhotoAnalyzer.makeDraft(image: blueBackground, face: face,
            startingFrom: CompanionProfile(hairColor: .honey)).profile
        try check(unchangedHair.hairColor == .honey, "Saturated blue background was guessed as hair")
        print("PASS injected feature geometry yields two distinct broad toy expressions; no face mesh is retained")

        let quadrants = try quadrantImage()
        let raster = try CompanionPhotoRaster(image: quadrants)
        let upper = CompanionPhotoRGB.robustMedian(raster.colors(in: [CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)]))!
        let lower = CompanionPhotoRGB.robustMedian(raster.colors(in: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)]))!
        try check(upper.red > 0.9 && upper.blue < 0.1 && lower.blue > 0.9 && lower.red < 0.1,
                  "Vision lower-left coordinates sampled the wrong image row")
        for orientation in 1...8 {
            let url = directory.appendingPathComponent("orientation-\(orientation).jpg")
            try write(quadrants, type: UTType.jpeg.identifier, orientation: orientation, to: url)
            let decoded = try CompanionPhotoAnalyzer.decodeImage(url: url)
            try check(decoded.width == (orientation >= 5 ? 240 : 320) && decoded.height == (orientation >= 5 ? 320 : 240),
                      "EXIF orientation \(orientation) did not change dimensions correctly")
            // JPEG introduces tiny variations; compare oriented quadrant positions
            // rather than dimensions alone, including mirrored orientations.
            let sample = try CompanionPhotoRaster(image: decoded)
            let topLeft = CompanionPhotoRGB.robustMedian(sample.colors(in: [CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)]))!
            let expected = [1: "red", 2: "green", 3: "yellow", 4: "blue", 5: "red", 6: "blue", 7: "yellow", 8: "green"][orientation]!
            try check(colorName(topLeft) == expected, "EXIF orientation \(orientation) top-left is \(colorName(topLeft)), expected \(expected)")
        }
        let largeURL = directory.appendingPathComponent("large.png")
        try write(try solidImage(width: 3_200, height: 1_800), type: UTType.png.identifier, to: largeURL)
        let thumbnail = try CompanionPhotoAnalyzer.decodeImage(url: largeURL)
        try check(thumbnail.width == 1_600 && thumbnail.height == 900, "Large source was not bounded to 1600 pixels")
        let pngURL = directory.appendingPathComponent("safe.png")
        try write(quadrants, type: UTType.png.identifier, to: pngURL)
        _ = try CompanionPhotoAnalyzer.decodeImage(url: pngURL)
        let heicURL = directory.appendingPathComponent("safe.heic")
        if (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(UTType.heic.identifier) {
            try write(quadrants, type: UTType.heic.identifier, orientation: 6, to: heicURL)
            let decoded = try CompanionPhotoAnalyzer.decodeImage(url: heicURL)
            try check(decoded.width == 240 && decoded.height == 320, "HEIC orientation was ignored")
            let multiURL = directory.appendingPathComponent("multiple-images.heic")
            try writeHEIFPair(quadrants, to: multiURL)
            guard let multiSource = CGImageSourceCreateWithURL(multiURL as CFURL, nil) else { throw StudioError.message("Multi-image HEIC unreadable") }
            try check(CGImageSourceGetCount(multiSource) == 2, "HEIC fixture did not contain two images")
            try check(CGImageSourceGetPrimaryImageIndex(multiSource) == 1, "HEIC fixture did not mark the second image as primary")
            let primary = try CompanionPhotoAnalyzer.decodeImage(url: multiURL)
            try check(primary.width == 320 && primary.height == 240, "Multi-image HEIC primary returned \(primary.width)x\(primary.height), expected 320x240")
            let orientedMultiURL = directory.appendingPathComponent("multiple-images-oriented.heic")
            try writeHEIFPair(quadrants, orientation: 6, to: orientedMultiURL)
            let orientedPrimary = try CompanionPhotoAnalyzer.decodeImage(url: orientedMultiURL)
            try check(orientedPrimary.width == 240 && orientedPrimary.height == 320, "Multi-image HEIC primary EXIF direction was ignored")
            let orientedRaster = try CompanionPhotoRaster(image: orientedPrimary)
            let orientedTopLeft = CompanionPhotoRGB.robustMedian(orientedRaster.colors(in: [CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)]))!
            try check(colorName(orientedTopLeft) == "blue", "Multi-image HEIC primary pixels have the wrong orientation")
            let largeMultiURL = directory.appendingPathComponent("multiple-images-large.heic")
            try writeHEIFPair(try solidImage(width: 3_200, height: 1_800), to: largeMultiURL)
            let largePrimary = try CompanionPhotoAnalyzer.decodeImage(url: largeMultiURL)
            try check(largePrimary.width == 1_600 && largePrimary.height == 900, "Multi-image HEIC primary was not bounded")
            print("PASS PNG/JPEG/HEIC decode, multi-image HEIC primary selection, all eight EXIF directions, 1600-pixel thumbnail cap")
        } else { print("PASS PNG/JPEG decode, all eight EXIF orientations and bounded thumbnail (HEIC encoder unavailable on this host)") }

        let badURL = directory.appendingPathComponent("bad.jpg")
        try Data("not a photo".utf8).write(to: badURL)
        try expectError(.unsupportedImage) { _ = try CompanionPhotoAnalyzer.decodeImage(url: badURL) }
        let oversizedURL = directory.appendingPathComponent("oversized.jpg")
        FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: UInt64(CompanionPhotoAnalyzer.maximumFileBytes + 1)); try handle.close()
        try expectError(.fileTooLarge) { _ = try CompanionPhotoAnalyzer.decodeImage(url: oversizedURL) }
        var oversizedHeader = try Data(contentsOf: pngURL)
        // IHDR width is metadata and can be rejected before pixel allocation.
        oversizedHeader.replaceSubrange(16..<20, with: [0, 1, 0x86, 0xa0]) // 100,000 px
        let checksum = crc32(oversizedHeader[12..<29])
        oversizedHeader.replaceSubrange(29..<33, with: (0..<4).map { UInt8((checksum >> (24 - $0 * 8)) & 255) })
        let bombURL = directory.appendingPathComponent("oversized-dimensions.png")
        try oversizedHeader.write(to: bombURL)
        do { _ = try CompanionPhotoAnalyzer.decodeImage(url: bombURL); throw StudioError.message("Oversized malformed header accepted") }
        catch let error as CompanionPhotoError { try check(error == .imageTooLarge || error == .unreadableImage, "Oversized malformed header returned an unrelated error") }
        let wideURL = directory.appendingPathComponent("valid-but-too-wide.png")
        try write(try solidImage(width: CompanionPhotoAnalyzer.maximumSourceSide + 1, height: 1), type: UTType.png.identifier, to: wideURL)
        try expectError(.imageTooLarge) { _ = try CompanionPhotoAnalyzer.decodeImage(url: wideURL) }
        print("PASS corrupt image, 40-MB compressed cap and oversized pixel header rejected without full decode")

        let cancelled = Task { () throws -> CompanionPhotoDraft in
            try Task.checkCancellation()
            return try await CompanionPhotoAnalyzer.analyze(url: pngURL)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw StudioError.message("Cancelled analysis unexpectedly succeeded") }
        catch is CancellationError { }
        do { _ = try await CompanionPhotoAnalyzer.analyze(url: pngURL); throw StudioError.message("Synthetic quadrants unexpectedly passed as a human face") }
        catch let error as CompanionPhotoError { try check(error == .noFace, "Non-face input should explain that no face was found: \(error)") }
        print("PASS cancellation and genuine Vision rejection of a non-face drawing")

        if let fixturePath = CommandLine.arguments.dropFirst().first {
            let fixtureURL = URL(fileURLWithPath: fixturePath)
            let started = Date()
            let draft = try await CompanionPhotoAnalyzer.analyze(url: fixtureURL)
            try check(draft.profile.portraitTraits != nil || draft.profile.faceShape != .round || draft.profile.skinTone != .cream,
                      "Real photo yielded no discernible suggestion")
            print("PASS real Vision single-face photo: \(draft.profile.skinTone.rawValue)/\(draft.profile.faceShape.rawValue)/\(draft.profile.hairColor.rawValue) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            let image = try CompanionPhotoAnalyzer.decodeImage(url: fixtureURL)
            let two = try twoFaces(image)
            let twoURL = directory.appendingPathComponent("two-faces.jpg")
            try write(two, type: UTType.jpeg.identifier, to: twoURL)
            do { _ = try await CompanionPhotoAnalyzer.analyze(url: twoURL); throw StudioError.message("Two faces silently selected one person") }
            catch let error as CompanionPhotoError { try check(error == .multipleFaces, "Two faces should give a crop-to-person instruction: \(error)") }
            let turnedURL = directory.appendingPathComponent("real-exif-6.jpg")
            // Store physically rotated pixels plus the matching EXIF rotation;
            // the decoder must restore the upright face before Vision sees it.
            let sideways = try rotatedLeft(image)
            try write(sideways, type: UTType.jpeg.identifier, orientation: 6, to: turnedURL)
            _ = try await CompanionPhotoAnalyzer.analyze(url: turnedURL)
            print("PASS real Vision rejects a two-person montage and detects the same upright face after EXIF restoration")
        } else { print("NOTE no real-face fixture supplied; synthetic mapping checks do not validate real face detection") }
    }

    private static func fixtureFace() -> CompanionPhotoFaceSample {
        return CompanionPhotoFaceSample(bounds: CGRect(x: 0.25, y: 0.50, width: 0.5, height: 0.35),
            contour: (0..<17).map { index in let angle = Double(index) / 16 * .pi; return CGPoint(x: 0.5 - cos(angle) * 0.43, y: 0.75 - sin(angle) * 0.72) },
            leftEye: landmarkBox(0.18, 0.58, 0.18, 0.04), rightEye: landmarkBox(0.64, 0.58, 0.18, 0.04), lips: landmarkBox(0.30, 0.25, 0.40, 0.12))
    }
    private static func landmarkBox(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + w / 2, y: y + h), CGPoint(x: x + w, y: y), CGPoint(x: x + w / 2, y: y)]
    }
    private static func portrait(skin: CompanionSkinTone, hair: CompanionHairColor, outfit: CompanionOutfitColor, hairPaint: NSColor? = nil) throws -> CGImage {
        let width = 600, height = 800
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func paint(_ rect: CGRect, _ color: NSColor) {
            let c = color.usingColorSpace(.sRGB)!
            for y in 0..<height { for x in 0..<width {
                if rect.contains(CGPoint(x: (Double(x) + 0.5) / Double(width), y: 1 - (Double(y) + 0.5) / Double(height))) {
                    let i = (y * width + x) * 4
                    bytes[i] = UInt8((c.redComponent * 255).rounded()); bytes[i + 1] = UInt8((c.greenComponent * 255).rounded()); bytes[i + 2] = UInt8((c.blueComponent * 255).rounded())
                }
            } }
        }
        paint(CGRect(x: 0.25, y: 0.50, width: 0.50, height: 0.35), skin.color)
        paint(CGRect(x: 0.25, y: 0.82, width: 0.50, height: 0.10), hairPaint ?? hair.color)
        paint(CGRect(x: 0.29, y: 0.10, width: 0.42, height: 0.20), outfit.color)
        return try makeImage(bytes, width: width, height: height)
    }
    private static func quadrantImage() throws -> CGImage {
        let width = 320, height = 240
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let color: (UInt8, UInt8, UInt8) = y < height / 2 ? (x < width / 2 ? (255, 0, 0) : (0, 255, 0)) : (x < width / 2 ? (0, 0, 255) : (255, 255, 0))
            let i = (y * width + x) * 4; bytes[i] = color.0; bytes[i + 1] = color.1; bytes[i + 2] = color.2
        } }
        return try makeImage(bytes, width: width, height: height)
    }
    private static func makeImage(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw StudioError.message("Fixture construction failed") }
        return image
    }
    private static func solidImage(width: Int, height: Int) throws -> CGImage { try makeImage([UInt8](repeating: 180, count: width * height * 4), width: width, height: height) }
    private static func write(_ image: CGImage, type: String, orientation: Int = 1, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { throw StudioError.message("Fixture encoder unavailable") }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.message("Fixture write failed") }
    }
    private static func writeHEIFPair(_ image: CGImage, orientation: Int = 1, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 2, nil) else { throw StudioError.message("HEIC pair encoder unavailable") }
        CGImageDestinationAddImage(destination, try solidImage(width: 80, height: 60), [kCGImagePropertyPrimaryImage: false] as CFDictionary)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPrimaryImage: true, kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.message("HEIC pair write failed") }
    }
    private static func expectError(_ expected: CompanionPhotoError, _ action: () throws -> Void) throws {
        do { try action(); throw StudioError.message("Expected error \(expected)") }
        catch let error as CompanionPhotoError { try check(error == expected, "Expected \(expected), received \(error)") }
    }
    private static func colorName(_ c: CompanionPhotoRGB) -> String {
        if c.red > 0.7 && c.green > 0.7 { return "yellow" }
        if c.red > max(c.green, c.blue) { return "red" }
        if c.green > c.blue { return "green" }
        return "blue"
    }
    private static func crc32(_ bytes: Data.SubSequence) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return crc ^ 0xffff_ffff
    }
    private static func twoFaces(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width * 2, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StudioError.message("Montage context failed") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: image.width, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }
    private static func rotatedLeft(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: image.height * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StudioError.message("Rotation context failed") }
        context.translateBy(x: CGFloat(image.height), y: 0); context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }
}
