import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Public documentation samples, produced by the application's actual PNG exporter.
/// Only the repository's original demo image and the text below are used.
@main struct MakeShowcaseOutputs {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do { try await run() }
        catch {
            fputs("Showcase export failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw StudioError.message("请提供临时输出文件夹。")
        }
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let batches = output.appendingPathComponent("batches", isDirectory: true)
        try FileManager.default.createDirectory(at: batches, withIntermediateDirectories: true)

        // Do not inspect user media, saved projects, preferences, or speech settings.
        // The same public image and sentence make the styles directly comparable.
        let clip = MediaClip(url: repository.appendingPathComponent("Resources/demo-coast.png"),
                             name: "海边示例", kind: .image, duration: 4, sourceDuration: 4)
        let thought = "那天下午什么也没做，却是整趟旅行最舒服的时候。"
        let styles: [(String, CaptionStyle)] = [
            ("subtitle", .subtitle), ("sticker", .sticker),
            ("note", .note), ("companion", .companion)
        ]
        for (name, style) in styles {
            try await make(clip: clip, text: thought, style: style, format: .landscape,
                           name: "caption-\(name).png", batches: batches, output: output)
        }
        let formats: [(String, VideoFormat)] = [
            ("landscape", .landscape), ("portrait", .portrait), ("square", .square)
        ]
        for (name, format) in formats {
            try await make(clip: clip, text: thought, style: .companion, format: format,
                           name: "export-\(name).png", batches: batches, output: output)
        }
    }

    @MainActor private static func make(clip: MediaClip, text: String, style: CaptionStyle,
                                       format: VideoFormat, name: String, batches: URL, output: URL) async throws {
        let caption = Caption(clipID: clip.id, start: 0, duration: clip.duration, text: text, style: style)
        let urls = try await CaptionImageExporter.export(clips: [clip], captions: [caption],
                                                         format: format, to: batches) { _ in }
        guard urls.count == 1, let original = urls.first,
              let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == Int(format.size.width), image.height == Int(format.size.height) else {
            throw StudioError.message("示例图片缺失或尺寸不正确：\(name)")
        }
        let destination = output.appendingPathComponent(name)
        try FileManager.default.copyItem(at: original, to: destination)
        print("\(name): \(image.width) × \(image.height)")
    }
}
