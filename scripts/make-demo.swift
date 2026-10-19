import AppKit
import Foundation

/// Generates only original sample media; never touches the user's working project.
@main struct DemoMaker {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = root.appendingPathComponent("Resources")
        let names = ["海边的午后", "山野里的风", "不想结束的傍晚"]
        let files = ["demo-coast.png", "demo-hills.png", "demo-evening.png"]
        var clips: [MediaClip] = []
        for (name, filename) in zip(names, files) {
            var clip = try await MediaEngine.inspect(url: resources.appendingPathComponent(filename))
            clip.name = name; clip.duration = 4; clips.append(clip)
        }
        var captions = [
            Caption(clipID: clips[0].id, start: 0, duration: 4, text: "那天下午什么也没做，\n却是整趟旅行最舒服的时候。", style: .sticker),
            Caption(clipID: clips[1].id, start: 0, duration: 4, text: "慢一点，才能听见山里的风。", style: .note),
            Caption(clipID: clips[2].id, start: 0, duration: 4, text: "想把这样的傍晚，多留一会儿。", style: .subtitle)
        ]
        let plan = try await AutoEditEngine.plan(clips: clips, captions: captions, musicURL: resources.appendingPathComponent("breeze.wav")) { _, _ in }
        clips = plan.clips; captions = plan.captions
        let output = root.appendingPathComponent("dist/映述示例短片.mp4")
        try await MediaEngine.export(settings: ExportSettings(clips: clips, captions: captions, format: .landscape,
            musicURL: resources.appendingPathComponent("breeze.wav"), musicVolume: 0.32, outputURL: output)) { _ in }
        let doc = ProjectDocument(title: "海边散步的一天", clips: clips, captions: captions, format: .landscape, musicID: "breeze", musicVolume: 0.32, automaticEditEnabled: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(doc).write(to: root.appendingPathComponent("dist/映述示例项目.yingshu.json"), options: .atomic)
        print("PASS: generated \(String(format: "%.2f", clips.totalDuration))-second, three-style original demonstration and editable sample project; \(plan.summary)")
    }
}
