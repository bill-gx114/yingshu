import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw StudioError.message(message) }
}
private final class ExportProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private var invalid = false
    func receive(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        invalid = invalid || !value.isFinite || value < last || value < 0 || value > 1
        last = value
    }
    func verify(completed: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try require(!invalid && (completed ? last == 1 : last < 1), "Invalid progress or premature success")
    }
}
private final class CancelSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var action: (@Sendable () -> Void)?
    func attach(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); let invoke = requested
        if !invoke { self.action = action }
        lock.unlock(); if invoke { action() }
    }
    func request() {
        lock.lock(); requested = true; let action = action; self.action = nil; lock.unlock(); action?()
    }
}
@main struct CaptionImageExportChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); Foundation.exit(1) }
    }
    @MainActor private static func run() async throws {
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let run = project.appendingPathComponent("Tests/output/caption-images", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = run.appendingPathComponent("generated-sources", isDirectory: true)
        let output = run.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photoURL = sources.appendingPathComponent("oriented-caption.jpg")
        try createPhoto(url: photoURL)
        let original = try Data(contentsOf: photoURL)
        var photo = try await MediaEngine.inspect(url: photoURL); photo.duration = 4; photo.name = "海边/方向,夏天"
        let fixture = project.appendingPathComponent("Tests/fixtures/live-photo", isDirectory: true)
        var video = try await MediaEngine.inspect(url: fixture.appendingPathComponent("iphone-style-motion.mov"))
        video.duration = 2; video.livePhotoStillURL = fixture.appendingPathComponent("iphone-style-still.heic")
        var uncaptioned = photo; uncaptioned.id = UUID(); uncaptioned.url = sources.appendingPathComponent("not-needed.jpg")
        let captions = [
            Caption(clipID: photo.id, start: 0, duration: 1, text: "海边第一句", style: .subtitle),
            Caption(clipID: photo.id, start: 1, duration: 1, text: "今天慢一点", style: .sticker),
            Caption(clipID: photo.id, start: 1.5, duration: 1.5, text: "把这刻记住", style: .note),
            Caption(clipID: video.id, start: 0, duration: 0.8, text: "动态前半段", style: .sticker),
            Caption(clipID: video.id, start: 1.2, duration: 0.8, text: "动态后半段", style: .note),
            Caption(clipID: uncaptioned.id, start: 0, duration: 1, text: " \n ", style: .subtitle)
        ]
        for format in VideoFormat.allCases {
            let progress = ExportProgress()
            let urls = try await CaptionImageExporter.export(clips: [photo, uncaptioned, video], captions: captions,
                format: format, to: output) { progress.receive($0) }
            try progress.verify(completed: true)
            try require(urls.count == 6, "Timed/overlapping caption groups were omitted or empty captions exported")
            try require(urls.map(\.lastPathComponent) == urls.map(\.lastPathComponent).sorted(), "PNG filenames do not preserve project order")
            try require(Set(urls.map { $0.deletingLastPathComponent() }).count == 1, "Export did not commit one batch directory")
            var images: [CGImage] = []
            for url in urls {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetType(source) as String? == UTType.png.identifier,
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StudioError.message("Incomplete PNG output") }
                try require(image.width == Int(format.size.width) && image.height == Int(format.size.height), "Wrong image canvas")
                try require(image.bitsPerComponent == 8, "Expected ordinary 8-bit PNG")
                images.append(image)
            }
            let expected = ["海边第一句", "今天慢一点", "今天慢一点把这刻记住", "把这刻记住", "动态前半段", "动态后半段"]
            for (index, image) in images.enumerated() {
                let recognised = try recognise(image)
                for text in ["海边第一句", "今天慢一点", "把这刻记住", "动态前半段", "动态后半段"] where expected[index].contains(text) {
                    try require(recognised.contains(text), "Missing, inverted or unreadable text in PNG \(index + 1): \(recognised)")
                }
            }
            if format == .portrait {
                let corner = pixel(images[0], x: 0.2, y: 0.2)
                try require(corner[2] > 0.7 && corner[0] < 0.3, "Original photo EXIF rotation was lost")
            }
            if format == .landscape {
                try require(pixel(images[0], x: 0.03, y: 0.5).allSatisfy { $0 < 0.04 }, "Photo fit did not preserve black letterbox")
            }
            let early = pixel(images[4], x: 0.5, y: 0.5), later = pixel(images[5], x: 0.5, y: 0.5)
            try require(zip(early, later).map { abs($0 - $1) }.reduce(0, +) > 0.5, "Live/video export reused one still poster instead of the timed frame")
            let batch = urls[0].deletingLastPathComponent()
            let index = try String(contentsOf: batch.appendingPathComponent("index.csv"), encoding: .utf8)
            let explanation = try String(contentsOf: batch.appendingPathComponent("导出说明.txt"), encoding: .utf8)
            try require(index.contains("把这刻记住") && index.contains("1.500") && !index.contains(project.path), "Index is missing text/time or exposes absolute source paths")
            try require(explanation.contains("剪映") && explanation.contains("PNG 本身不会播放动态"), "Handoff instructions are missing")
            print("PASS: \(format.rawValue), six ordered 8-bit PNGs; OCR proves all three styles and timed/overlap captions; actual Live Photo frames differ")
        }
        try require(try Data(contentsOf: photoURL) == original, "Export changed the original image")
        let sentinel = output.appendingPathComponent("已有文件.txt")
        try Data("preserve existing output".utf8).write(to: sentinel)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: output.path))
        let corruptURL = sources.appendingPathComponent("corrupt.jpg")
        try Data("corrupt picture".utf8).write(to: corruptURL)
        var corrupt = photo; corrupt.id = UUID(); corrupt.url = corruptURL
        let invalid = captions.filter { $0.clipID == photo.id } + [Caption(clipID: corrupt.id, start: 0, duration: 1, text: "必须报错")]
        let failingProgress = ExportProgress()
        var failed = false
        do { _ = try await CaptionImageExporter.export(clips: [photo, corrupt], captions: invalid, format: .landscape, to: output) { failingProgress.receive($0) } }
        catch { failed = true }
        try require(failed, "Corrupt source unexpectedly succeeded")
        try failingProgress.verify(completed: false)
        try require(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == before, "Failure left a partial image batch")
        let signal = CancelSignal(), cancelledProgress = ExportProgress()
        let cancelled = Task {
            try await CaptionImageExporter.export(clips: [photo, video], captions: captions.filter { $0.clipID != uncaptioned.id },
                format: .landscape, to: output) { value in
                cancelledProgress.receive(value)
                if value > 0 && value < 1 { signal.request() }
            }
        }
        signal.attach { cancelled.cancel() }
        do { _ = try await cancelled.value; throw StudioError.message("Cancelled image batch reported success") }
        catch is CancellationError { }
        try cancelledProgress.verify(completed: false)
        try require(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == before, "Cancellation left a partial batch or touched existing files")
        try require(try String(contentsOf: sentinel, encoding: .utf8) == "preserve existing output", "Existing output was overwritten")
        var emptyRejected = false
        do { _ = try await CaptionImageExporter.export(clips: [photo], captions: [], format: .square, to: output) { _ in } }
        catch { emptyRejected = true }
        try require(emptyRejected, "Empty captions were reported as exported")
        print("PASS: errors/cancellation leave no partial set, no premature 100 percent, existing files and originals unchanged; empty export rejected")
        print("ALL CAPTION IMAGE EXPORT CHECKS PASSED: \(run.path)")
    }
    private static func createPhoto(url: URL) throws {
        let width = 640, height = 360
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let rgb: [UInt8] = y < height / 2 ? (x < width / 2 ? [255, 0, 0] : [0, 255, 0]) : (x < width / 2 ? [0, 0, 255] : [255, 255, 0])
            let position = (y * width + x) * 4
            bytes[position] = rgb[0]; bytes[position + 1] = rgb[1]; bytes[position + 2] = rgb[2]
        } }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "Cannot save generated photo")
    }
    private static func recognise(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().filter { !$0.isWhitespace }
    }
    private static func pixel(_ image: CGImage, x: Double, y: Double) -> [Double] {
        var result = [UInt8](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let sampleX = CGFloat(Int(x * Double(image.width - 1))), sampleY = CGFloat(Int((1 - y) * Double(image.height - 1)))
            context.draw(image, in: CGRect(x: -sampleX, y: -sampleY, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return result.prefix(3).map { Double($0) / 255 }
    }
}
